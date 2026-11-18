#!/usr/bin/env python3
"""Propagate the active Omarchy theme from WSL to Windows Terminal and VS Code.

Usage:
  omarchy-theme-bridge [THEME]            sync Windows Terminal + VS Code
  omarchy-theme-bridge --check            report what would be synced
  omarchy-theme-bridge --print-scheme     print the Windows Terminal scheme
  omarchy-theme-bridge --emit-terminal-profile
                                          print a WSL terminal profile template

THEME is a theme name ("Tokyo Night"), a theme directory or a colors.toml
path. Without it the currently applied theme is used
(~/.local/state/omarchy/current/theme), falling back to Tokyo Night.

Windows Terminal: the theme becomes a color scheme named "Omarchy <Theme>"
(upserted into "schemes") and the profile of this WSL distribution switches to
it. Terminal hot-reloads settings.json, so open windows recolor immediately.

VS Code / VSCodium / Cursor: "workbench.colorTheme" is set to the theme named in
the Omarchy theme's vscode.json when that extension is installed on Windows.

Both settings files are JSONC. Only the values that change are rewritten, so
comments and formatting elsewhere survive; writes are atomic (temp file +
rename) and the previous file is kept as <file>.omarchy-backup.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

SCHEME_PREFIX = "Omarchy "
DEFAULT_THEME = "Tokyo Night"

# Upstream themes/tokyo-night/colors.toml, used when no Omarchy tree is around
# (for example when running this script from the repository on another host).
TOKYO_NIGHT = {
    "mode": "dark",
    "accent": "#7aa2f7",
    "selection": "#292e42",
    "muted": "#414868",
    "background": "#1a1b26",
    "dark_background": "#13141c",
    "darker_background": "#0e0e14",
    "lighter_background": "#24283b",
    "foreground": "#a9b1d6",
    "dark_foreground": "#565f89",
    "light_foreground": "#b4bee6",
    "bright_foreground": "#c0caf5",
    "red": "#f7768e",
    "yellow": "#e0af68",
    "orange": "#eb927b",
    "green": "#9ece6a",
    "cyan": "#449dab",
    "blue": "#7aa2f7",
    "magenta": "#ad8ee6",
    "brown": "#75493d",
    "bright_red": "#ff7a93",
    "bright_yellow": "#ff9e64",
    "bright_green": "#b9f27c",
    "bright_cyan": "#0db9d7",
    "bright_blue": "#7da6ff",
    "bright_magenta": "#bb9af7",
}
TOKYO_NIGHT_VSCODE = {"name": "Tokyo Night", "extension": "enkia.tokyo-night"}

WT_ANSI_KEYS = [
    "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow",
    "brightBlue", "brightPurple", "brightCyan", "brightWhite",
]

VSCODE_FLAVORS = [
    # (settings dir under %APPDATA%, extensions dir under %USERPROFILE%)
    ("Code", ".vscode"),
    ("Code - Insiders", ".vscode-insiders"),
    ("VSCodium", ".vscode-oss"),
    ("Cursor", ".cursor"),
]


class BridgeError(Exception):
    pass


# --------------------------------------------------------------------------
# Theme loading and palette resolution (port of upstream omarchy-theme-color)
# --------------------------------------------------------------------------

_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")
_VALUE_RE = re.compile(r"^[A-Za-z0-9#(),._+/% -]*$")
_HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


def parse_colors_toml(text: str) -> dict[str, str]:
    """Parse colors.toml exactly the way omarchy-theme-color does."""
    colors: dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
        else:
            key, value = line, ""
        key = re.sub(r"[\"' ]", "", key)
        if not key or key.startswith("#"):
            continue
        if '"' in value or "'" in value:
            value = re.split(r"[\"']", value, maxsplit=1)[1]
            value = re.split(r"[\"']", value, maxsplit=1)[0]
        else:
            value = value.strip()
        if not _KEY_RE.match(key) or not _VALUE_RE.match(value):
            continue
        colors[key] = value
    return colors


def mix_color(start: str, end: str, amount: float) -> str:
    if not (_HEX_RE.match(start or "") and _HEX_RE.match(end or "")):
        return ""
    a = [int(start[i : i + 2], 16) for i in (1, 3, 5)]
    b = [int(end[i : i + 2], 16) for i in (1, 3, 5)]
    mixed = [int(x * (1 - amount) + y * amount + 0.5) for x, y in zip(a, b)]
    return "#{:02x}{:02x}{:02x}".format(*mixed)


def resolve_palette(raw: dict[str, str]) -> dict[str, str]:
    """Apply upstream's alias/fallback cascade so every key a terminal needs exists."""
    c = dict(raw)

    def get(key: str) -> str:
        return c.get(key, "") or ""

    def alias(key: str, fallback: str) -> None:
        if not get(key):
            c[key] = get(fallback)

    legacy_palette = {
        "background": "bg", "dark_background": "dark_bg",
        "darker_background": "darker_bg", "lighter_background": "lighter_bg",
        "foreground": "fg", "dark_foreground": "dark_fg",
        "light_foreground": "light_fg", "bright_foreground": "bright_fg",
    }
    for key, short in legacy_palette.items():
        alias(key, short)

    if not get("background"):
        c["background"] = get("color0")
    if not get("foreground"):
        c["foreground"] = get("color7")
    if get("background"):
        c["color0"] = get("background")
    if get("foreground"):
        c["color7"] = get("foreground")

    legacy_ansi = {
        "red": "color1", "green": "color2", "yellow": "color3", "blue": "color4",
        "magenta": "color5", "cyan": "color6", "bright_red": "color9",
        "bright_green": "color10", "bright_yellow": "color11",
        "bright_blue": "color12", "bright_magenta": "color13", "bright_cyan": "color14",
    }
    for key, ansi in legacy_ansi.items():
        alias(key, ansi)
    alias("magenta", "purple")
    alias("bright_magenta", "bright_purple")

    def default(key: str, *fallbacks: str) -> None:
        if get(key):
            return
        for fb in fallbacks:
            if get(fb):
                c[key] = get(fb)
                return
        c[key] = ""

    default("light_foreground", "color7", "foreground")
    default("bright_foreground", "color15", "foreground")
    c["cursor"] = get("bright_foreground")
    default("lighter_background", "color0", "background")
    default("dark_foreground", "color8", "foreground")
    default("muted", "color8", "dark_foreground")
    default("selection", "selection_background", "color8", "color0", "background")
    default("selection_background", "selection")
    default("selection_foreground", "bright_foreground")
    default("orange", "yellow")
    if not get("brown"):
        c["brown"] = mix_color(get("orange"), "#000000", 0.5)

    if not get("dark_background"):
        c["dark_background"] = mix_color(get("background"), "#000000", 0.25)
    if not get("darker_background"):
        c["darker_background"] = mix_color(get("background"), "#000000", 0.5)
    for name in ("red", "yellow", "green", "cyan", "blue", "magenta"):
        if not get(f"bright_{name}"):
            c[f"bright_{name}"] = mix_color(get(name), "#ffffff", 0.2)
    alias("purple", "magenta")
    alias("bright_purple", "bright_magenta")

    ansi = [
        "background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground",
        "muted", "bright_red", "bright_green", "bright_yellow", "bright_blue",
        "bright_magenta", "bright_cyan", "bright_foreground",
    ]
    for i, semantic in enumerate(ansi):
        alias(f"color{i}", semantic)

    for key, short in legacy_palette.items():
        if get(key):
            c[short] = get(key)

    if not get("mode"):
        c["mode"] = get("theme_type")
    if not get("mode"):
        bg = get("background")
        if _HEX_RE.match(bg):
            lum = sum(int(bg[i : i + 2], 16) for i in (1, 3, 5))
            c["mode"] = "light" if lum > 382 else "dark"
        else:
            c["mode"] = "dark"
    c["theme_type"] = c["mode"]
    return c


@dataclass
class Theme:
    name: str  # display name, e.g. "Tokyo Night"
    palette: dict[str, str]
    vscode: Optional[dict[str, str]] = None
    source: str = ""

    @property
    def scheme_name(self) -> str:
        return SCHEME_PREFIX + self.name


def slug_to_display(slug: str) -> str:
    return " ".join(part[:1].upper() + part[1:] for part in slug.split("-") if part)


def display_to_slug(name: str) -> str:
    return re.sub(r"<[^>]+>", "", name).lower().replace(" ", "-")


def omarchy_path() -> Path:
    return Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy")


def current_theme_dir() -> Path:
    return Path.home() / ".local/state/omarchy/current/theme"


def theme_search_dirs(slug: str) -> list[Path]:
    return [
        Path.home() / ".config/omarchy/themes" / slug,
        omarchy_path() / "themes" / slug,
    ]


def load_theme(spec: Optional[str]) -> Theme:
    theme_dir: Optional[Path] = None
    name: Optional[str] = None

    if spec and (os.sep in spec or spec.endswith(".toml")):
        path = Path(spec).expanduser()
        theme_dir = path.parent if path.is_file() else path
        if not (theme_dir / "colors.toml").is_file():
            raise BridgeError(f"no colors.toml in {theme_dir}")
        name = slug_to_display(theme_dir.name)
    elif spec:
        slug = display_to_slug(spec)
        name = slug_to_display(slug)
        theme_dir = next((d for d in theme_search_dirs(slug) if (d / "colors.toml").is_file()), None)
        if theme_dir is None and slug != display_to_slug(DEFAULT_THEME):
            raise BridgeError(f"theme '{spec}' not found in " + ", ".join(map(str, theme_search_dirs(slug))))
    else:
        current = current_theme_dir()
        if (current / "colors.toml").is_file():
            theme_dir = current
            name_file = current.parent / "theme.name"
            slug = name_file.read_text().strip() if name_file.is_file() else "custom"
            name = slug_to_display(slug)
        else:
            name = DEFAULT_THEME
            slug = display_to_slug(DEFAULT_THEME)
            theme_dir = next((d for d in theme_search_dirs(slug) if (d / "colors.toml").is_file()), None)

    if theme_dir is None:
        return Theme(name=DEFAULT_THEME, palette=resolve_palette(TOKYO_NIGHT),
                     vscode=dict(TOKYO_NIGHT_VSCODE), source="built-in Tokyo Night")

    palette = resolve_palette(parse_colors_toml((theme_dir / "colors.toml").read_text()))
    vscode = None
    vscode_file = theme_dir / "vscode.json"
    if vscode_file.is_file():
        try:
            data = json.loads(vscode_file.read_text())
            if isinstance(data, dict) and data.get("name"):
                vscode = {"name": str(data["name"]), "extension": str(data.get("extension", ""))}
        except ValueError:
            vscode = None
    return Theme(name=name or "Custom", palette=palette, vscode=vscode, source=str(theme_dir))


def normalize_hex(value: str, fallback: str) -> str:
    value = (value or "").strip()
    if re.match(r"^#[0-9A-Fa-f]{3}$", value):
        value = "#" + "".join(ch * 2 for ch in value[1:])
    if _HEX_RE.match(value):
        return value.lower()
    return fallback


def terminal_scheme(theme: Theme) -> dict[str, str]:
    p = theme.palette
    bg = normalize_hex(p.get("background", ""), "#000000")
    fg = normalize_hex(p.get("foreground", ""), "#ffffff")
    scheme = {
        "name": theme.scheme_name,
        "background": bg,
        "foreground": fg,
        "cursorColor": normalize_hex(p.get("cursor", ""), fg),
        "selectionBackground": normalize_hex(p.get("selection_background", ""), fg),
    }
    for i, key in enumerate(WT_ANSI_KEYS):
        scheme[key] = normalize_hex(p.get(f"color{i}", ""), fg if i % 8 == 7 else bg if i == 0 else fg)
    return scheme


# --------------------------------------------------------------------------
# JSONC parsing with source spans, so edits leave the rest of the file alone
# --------------------------------------------------------------------------


@dataclass
class Node:
    kind: str  # "object" | "array" | "scalar"
    start: int
    end: int
    value: Any = None
    members: list[tuple[str, "Node"]] = field(default_factory=list)  # objects
    items: list["Node"] = field(default_factory=list)  # arrays

    def get(self, key: str) -> Optional["Node"]:
        for name, node in self.members:
            if name == key:
                return node
        return None

    def to_python(self) -> Any:
        if self.kind == "object":
            return {k: v.to_python() for k, v in self.members}
        if self.kind == "array":
            return [item.to_python() for item in self.items]
        return self.value


class JsoncParser:
    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def error(self, message: str) -> BridgeError:
        line = self.text.count("\n", 0, self.pos) + 1
        return BridgeError(f"invalid JSON at line {line}: {message}")

    def skip(self) -> None:
        text, n = self.text, len(self.text)
        while self.pos < n:
            ch = text[self.pos]
            if ch in " \t\r\n﻿":
                self.pos += 1
            elif text.startswith("//", self.pos):
                nl = text.find("\n", self.pos)
                self.pos = n if nl < 0 else nl + 1
            elif text.startswith("/*", self.pos):
                close = text.find("*/", self.pos + 2)
                if close < 0:
                    raise self.error("unterminated comment")
                self.pos = close + 2
            else:
                break

    def parse(self) -> Node:
        self.skip()
        node = self.value()
        self.skip()
        if self.pos != len(self.text):
            raise self.error("trailing content")
        return node

    def value(self) -> Node:
        self.skip()
        if self.pos >= len(self.text):
            raise self.error("unexpected end of input")
        ch = self.text[self.pos]
        if ch == "{":
            return self.obj()
        if ch == "[":
            return self.arr()
        if ch == '"':
            start = self.pos
            return Node("scalar", start, self.pos_after_string(), self.string_value(start))
        match = re.compile(r"-?\d+(\.\d+)?([eE][+-]?\d+)?|true|false|null").match(self.text, self.pos)
        if not match:
            raise self.error(f"unexpected character {ch!r}")
        self.pos = match.end()
        return Node("scalar", match.start(), match.end(), json.loads(match.group(0)))

    def pos_after_string(self) -> int:
        i = self.pos + 1
        text = self.text
        while i < len(text):
            if text[i] == "\\":
                i += 2
            elif text[i] == '"':
                self.pos = i + 1
                return self.pos
            else:
                i += 1
        raise self.error("unterminated string")

    def string_value(self, start: int) -> str:
        return json.loads(self.text[start : self.pos])

    def obj(self) -> Node:
        node = Node("object", self.pos, -1)
        self.pos += 1
        while True:
            self.skip()
            if self.pos >= len(self.text):
                raise self.error("unterminated object")
            if self.text[self.pos] == "}":
                self.pos += 1
                node.end = self.pos
                return node
            if self.text[self.pos] != '"':
                raise self.error("expected property name")
            start = self.pos
            self.pos_after_string()
            key = self.string_value(start)
            self.skip()
            if self.pos >= len(self.text) or self.text[self.pos] != ":":
                raise self.error("expected ':'")
            self.pos += 1
            node.members.append((key, self.value()))
            self.skip()
            if self.pos < len(self.text) and self.text[self.pos] == ",":
                self.pos += 1
            elif self.pos < len(self.text) and self.text[self.pos] != "}":
                raise self.error("expected ',' or '}'")

    def arr(self) -> Node:
        node = Node("array", self.pos, -1)
        self.pos += 1
        while True:
            self.skip()
            if self.pos >= len(self.text):
                raise self.error("unterminated array")
            if self.text[self.pos] == "]":
                self.pos += 1
                node.end = self.pos
                return node
            node.items.append(self.value())
            self.skip()
            if self.pos < len(self.text) and self.text[self.pos] == ",":
                self.pos += 1
            elif self.pos < len(self.text) and self.text[self.pos] != "]":
                raise self.error("expected ',' or ']'")


def parse_jsonc(text: str) -> Node:
    return JsoncParser(text).parse()


class JsoncDocument:
    """A JSONC file plus a queue of span edits applied back-to-front."""

    def __init__(self, text: str):
        self.bom = text.startswith("﻿")
        self.text = text[1:] if self.bom else text
        self.newline = "\r\n" if "\r\n" in self.text else "\n"
        self.root = parse_jsonc(self.text)
        if self.root.kind != "object":
            raise BridgeError("settings file is not a JSON object")
        self.indent_unit = self._detect_indent()
        self.edits: list[tuple[int, int, str]] = []

    def _detect_indent(self) -> str:
        match = re.search(r"\n([ \t]+)\S", self.text)
        return match.group(1) if match else "    "

    def line_indent(self, pos: int) -> str:
        line_start = self.text.rfind("\n", 0, pos) + 1
        match = re.match(r"[ \t]*", self.text[line_start:])
        return match.group(0) if match else ""

    def render(self, value: Any, base_indent: str) -> str:
        indent = len(self.indent_unit) if set(self.indent_unit) == {" "} else self.indent_unit
        dumped = json.dumps(value, indent=indent, ensure_ascii=False)
        return dumped.replace("\n", self.newline + base_indent)

    def replace(self, node: Node, value: Any) -> None:
        self.edits.append((node.start, node.end, self.render(value, self.line_indent(node.start))))

    def _child_indent(self, container: Node) -> str:
        children = [n for _, n in container.members] if container.kind == "object" else container.items
        if children:
            # A member's value shares its line with the key, so this is the
            # indentation existing siblings use.
            return self.line_indent(children[0].start)
        return self.line_indent(container.start) + self.indent_unit

    def _append(self, container: Node, fragment_for_indent) -> None:
        children = [n for _, n in container.members] if container.kind == "object" else container.items
        indent = self._child_indent(container)
        fragment = fragment_for_indent(indent)
        if children:
            last = children[-1]
            self.edits.append((last.end, last.end, "," + self.newline + indent + fragment))
        else:
            closing = self.newline + self.line_indent(container.start)
            self.edits.append((container.start + 1, container.start + 1,
                               self.newline + indent + fragment + closing))

    def set_member(self, obj: Node, key: str, value: Any) -> None:
        existing = obj.get(key)
        if existing is not None:
            if existing.to_python() != value:
                self.replace(existing, value)
            return
        self._append(obj, lambda indent: json.dumps(key) + ": " + self.render(value, indent))

    def append_item(self, arr: Node, value: Any) -> None:
        self._append(arr, lambda indent: self.render(value, indent))

    @property
    def changed(self) -> bool:
        return bool(self.edits)

    def result(self) -> str:
        text = self.text
        for start, end, replacement in sorted(self.edits, key=lambda e: e[0], reverse=True):
            text = text[:start] + replacement + text[end:]
        parse_jsonc(text)  # never write something we could not read back
        return ("﻿" if self.bom else "") + text


def write_atomically(path: Path, content: str) -> None:
    backup = path.with_name(path.name + ".omarchy-backup")
    shutil.copy2(path, backup)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# --------------------------------------------------------------------------
# Locating Windows-side files
# --------------------------------------------------------------------------


@dataclass
class WindowsHome:
    profile: Path  # %USERPROFILE%
    local_appdata: Path  # %LOCALAPPDATA%
    appdata: Path  # %APPDATA%


def _wslpath(windows_path: str) -> Optional[Path]:
    try:
        out = subprocess.run(["wslpath", "-u", windows_path], capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    match = re.match(r"^([A-Za-z]):\\(.*)$", windows_path)
    if match:
        return Path("/mnt") / match.group(1).lower() / match.group(2).replace("\\", "/")
    return None


def _windows_env() -> dict[str, str]:
    cmd = "/mnt/c/Windows/System32/cmd.exe"
    if not os.path.exists(cmd):
        return {}
    try:
        out = subprocess.run([cmd, "/d", "/c", "set"], capture_output=True, timeout=10, cwd="/mnt/c")
    except (OSError, subprocess.SubprocessError):
        return {}
    env = {}
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key.strip().upper()] = value.strip()
    return env


def find_windows_home(override: Optional[str]) -> Optional[WindowsHome]:
    if override:
        home = Path(override)
        return WindowsHome(home, home / "AppData/Local", home / "AppData/Roaming")

    env = _windows_env()
    if env.get("USERPROFILE"):
        profile = _wslpath(env["USERPROFILE"])
        local = _wslpath(env["LOCALAPPDATA"]) if env.get("LOCALAPPDATA") else None
        roaming = _wslpath(env["APPDATA"]) if env.get("APPDATA") else None
        if profile:
            return WindowsHome(profile, local or profile / "AppData/Local", roaming or profile / "AppData/Roaming")

    # Interop disabled: accept the only real profile under /mnt/c/Users.
    candidates = [
        Path(p) for p in glob.glob("/mnt/c/Users/*/AppData/Local")
        if Path(p).parts[-3] not in ("Public", "Default", "Default User", "All Users")
    ]
    if len(candidates) == 1:
        profile = candidates[0].parent.parent
        return WindowsHome(profile, profile / "AppData/Local", profile / "AppData/Roaming")
    return None


def terminal_settings_paths(home: WindowsHome) -> list[Path]:
    patterns = [
        "Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json",
        "Packages/Microsoft.WindowsTerminalPreview_*/LocalState/settings.json",
        "Packages/Microsoft.WindowsTerminalCanary_*/LocalState/settings.json",
        "Microsoft/Windows Terminal/settings.json",
    ]
    found: list[Path] = []
    for pattern in patterns:
        found.extend(Path(p) for p in sorted(glob.glob(str(home.local_appdata / pattern))))
    return found


def vscode_targets(home: WindowsHome) -> list[tuple[str, Path, Path]]:
    targets = []
    for flavor, ext_dir in VSCODE_FLAVORS:
        settings = home.appdata / flavor / "User" / "settings.json"
        if settings.is_file():
            targets.append((flavor, settings, home.profile / ext_dir / "extensions"))
    return targets


def extension_installed(ext_dir: Path, extension: str) -> bool:
    if not extension:
        return True
    prefix = extension.lower() + "-"
    try:
        return any(entry.name.lower().startswith(prefix) for entry in ext_dir.iterdir())
    except OSError:
        return False


# --------------------------------------------------------------------------
# Patching
# --------------------------------------------------------------------------


def profile_nodes(root: Node) -> list[Node]:
    profiles = root.get("profiles")
    if profiles is None:
        return []
    if profiles.kind == "object":
        listing = profiles.get("list")
        return listing.items if listing is not None and listing.kind == "array" else []
    if profiles.kind == "array":
        return profiles.items
    return []


def patch_terminal_settings(text: str, theme: Theme, profile_name: Optional[str],
                            font: Optional[str] = None) -> tuple[str, list[str]]:
    """Return (new_text, notes). new_text == text when nothing changed."""
    doc = JsoncDocument(text)
    scheme = terminal_scheme(theme)
    notes: list[str] = []

    schemes = doc.root.get("schemes")
    if schemes is None:
        doc.set_member(doc.root, "schemes", [scheme])
    elif schemes.kind != "array":
        raise BridgeError('"schemes" is not an array')
    else:
        existing = next((n for n in schemes.items if n.kind == "object" and n.to_python().get("name") == scheme["name"]), None)
        if existing is None:
            doc.append_item(schemes, scheme)
        elif existing.to_python() != scheme:
            doc.replace(existing, scheme)

    if profile_name:
        matches = [
            node for node in profile_nodes(doc.root)
            if node.kind == "object"
            and str(node.to_python().get("name", "")).casefold() == profile_name.casefold()
        ]
        if not matches:
            notes.append(f"no Windows Terminal profile named '{profile_name}'; "
                         f"scheme '{scheme['name']}' was added for manual selection")
        for node in matches:
            doc.set_member(node, "colorScheme", scheme["name"])
            if font:
                current_font = node.get("font")
                if current_font is not None and current_font.kind == "object":
                    doc.set_member(current_font, "face", font)
                else:
                    doc.set_member(node, "font", {"face": font})
    return (doc.result() if doc.changed else text), notes


def patch_vscode_settings(text: str, color_theme: str) -> str:
    if not text.strip():
        text = "{}\n"
    doc = JsoncDocument(text)
    doc.set_member(doc.root, "workbench.colorTheme", color_theme)
    return doc.result() if doc.changed else text


def terminal_profile_template(theme: Theme, font: Optional[str]) -> dict[str, Any]:
    profile: dict[str, Any] = {"colorScheme": theme.scheme_name}
    if font:
        profile["font"] = {"face": font}
    return {"profiles": [profile], "schemes": [terminal_scheme(theme)]}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


class Reporter:
    def __init__(self, quiet: bool):
        self.quiet = quiet

    def ok(self, message: str) -> None:
        if not self.quiet:
            print(f"ok: {message}")

    def warn(self, message: str) -> None:
        if not self.quiet:
            print(f"warn: {message}")


def sync(args: argparse.Namespace, theme: Theme, out: Reporter) -> int:
    home = find_windows_home(args.windows_home)
    profile_name = args.profile or os.environ.get("WSL_DISTRO_NAME")
    status = 0

    if args.settings:
        terminal_paths = [Path(p) for p in args.settings]
    elif os.environ.get("OMARCHY_WT_SETTINGS"):
        terminal_paths = [Path(os.environ["OMARCHY_WT_SETTINGS"])]
    else:
        terminal_paths = terminal_settings_paths(home) if home else []

    if not args.no_terminal:
        if home is None and not terminal_paths:
            out.warn("Windows user profile not found (interop off and /mnt/c ambiguous); skipping Windows Terminal")
        elif not terminal_paths:
            out.warn("Windows Terminal settings.json not found (launch Windows Terminal once to create it)")
        for path in terminal_paths:
            try:
                original = path.read_text(encoding="utf-8")
                updated, notes = patch_terminal_settings(original, theme, profile_name, args.font)
                for note in notes:
                    out.warn(note)
                if updated == original:
                    out.ok(f"Windows Terminal already on '{theme.scheme_name}' ({path})")
                elif args.check or args.dry_run:
                    out.ok(f"Windows Terminal would switch to '{theme.scheme_name}' ({path})")
                else:
                    write_atomically(path, updated)
                    out.ok(f"Windows Terminal switched to '{theme.scheme_name}' ({path})")
            except (OSError, BridgeError) as exc:
                print(f"Windows Terminal: {path}: {exc}", file=sys.stderr)
                status = 1

    if not args.no_vscode and home is not None:
        targets = vscode_targets(home)
        if args.vscode_settings:
            targets = [("VS Code", Path(p), home.profile / ".vscode" / "extensions") for p in args.vscode_settings]
        if not targets:
            out.warn("VS Code settings not found on Windows; skipping")
        for flavor, path, ext_dir in targets:
            if not theme.vscode:
                out.warn(f"theme '{theme.name}' has no vscode.json; leaving {flavor} alone")
                continue
            extension = theme.vscode.get("extension", "")
            if not extension_installed(ext_dir, extension):
                out.warn(f"{flavor}: install the '{extension}' extension to follow '{theme.name}'")
                continue
            try:
                original = path.read_text(encoding="utf-8")
                updated = patch_vscode_settings(original, theme.vscode["name"])
                if updated == original:
                    out.ok(f"{flavor} already on '{theme.vscode['name']}'")
                elif args.check or args.dry_run:
                    out.ok(f"{flavor} would switch to '{theme.vscode['name']}' ({path})")
                else:
                    write_atomically(path, updated)
                    out.ok(f"{flavor} switched to '{theme.vscode['name']}' ({path})")
            except (OSError, BridgeError) as exc:
                print(f"{flavor}: {path}: {exc}", file=sys.stderr)
                status = 1
    return status


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="omarchy-theme-bridge",
        description="Sync the Omarchy theme to Windows Terminal and VS Code.",
    )
    parser.add_argument("theme", nargs="?", help="theme name, theme directory or colors.toml (default: current theme)")
    parser.add_argument("--settings", action="append", default=[], metavar="PATH",
                        help="Windows Terminal settings.json to patch (repeatable; default: auto-detect)")
    parser.add_argument("--vscode-settings", action="append", default=[], metavar="PATH",
                        help="VS Code settings.json to patch (repeatable; default: auto-detect)")
    parser.add_argument("--windows-home", metavar="PATH",
                        help="Windows user profile as a Linux path, e.g. /mnt/c/Users/me (default: ask Windows)")
    parser.add_argument("--profile", help="Windows Terminal profile name (default: $WSL_DISTRO_NAME)")
    parser.add_argument("--font", help="also set the profile font face, e.g. 'JetBrainsMono Nerd Font'")
    parser.add_argument("--no-terminal", action="store_true", help="skip Windows Terminal")
    parser.add_argument("--no-vscode", action="store_true", help="skip VS Code")
    parser.add_argument("--dry-run", action="store_true", help="show what would change without writing")
    parser.add_argument("--check", action="store_true", help="report sync targets without writing")
    parser.add_argument("--quiet", action="store_true", help="only print errors")
    parser.add_argument("--print-scheme", action="store_true", help="print the Windows Terminal scheme JSON")
    parser.add_argument("--emit-terminal-profile", action="store_true",
                        help="print a WSL distribution terminal profile template")
    args = parser.parse_args(argv)

    try:
        theme = load_theme(args.theme)
    except (OSError, BridgeError) as exc:
        print(f"omarchy-theme-bridge: {exc}", file=sys.stderr)
        return 2

    if args.print_scheme:
        print(json.dumps(terminal_scheme(theme), indent=2))
        return 0
    if args.emit_terminal_profile:
        print(json.dumps(terminal_profile_template(theme, args.font), indent=2))
        return 0

    return sync(args, theme, Reporter(args.quiet))


if __name__ == "__main__":
    sys.exit(main())
