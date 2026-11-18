"""Omarchy Linux terminal adapters (Ghostty, Kitty, Alacritty).

Rules shared by every adapter:
  * Only terminals that are installed (binary on PATH) or already configured
    (config file present) are touched; nothing is created for the rest.
  * ``dry_run`` performs no filesystem writes at all (not even mkdir).
  * User configuration is never rewritten by pattern deletion: Omarchy content
    lives either in its own file (Kitty, Alacritty) or between explicit
    begin/end markers (Ghostty), and every change is a locked atomic update.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from omarchy_theme.adapters.windows_terminal import AdapterResult
from omarchy_theme.atomic_io import atomic_update_text, safe_read_text
from omarchy_theme.models import ColorScheme

try:  # Python >= 3.11
    import tomllib as _toml
except ModuleNotFoundError:  # pragma: no cover - exercised on old Pythons only
    _toml = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

BEGIN_MARK = "# >>> omarchy-theme-sync (managed block, do not edit) >>>"
END_MARK = "# <<< omarchy-theme-sync <<<"
ALACRITTY_THEME_FILE = "omarchy-theme.toml"

_HEX = r"#[0-9a-f]{6}"


def config_home() -> Path:
    """$XDG_CONFIG_HOME, else ~/.config."""
    xdg = os.environ.get("XDG_CONFIG_HOME", "")
    return Path(xdg) if xdg.startswith("/") else Path.home() / ".config"


def _available(binary: str, *configs: Path) -> bool:
    return shutil.which(binary) is not None or any(p.exists() for p in configs)


def _skipped(path: Path, name: str) -> AdapterResult:
    return AdapterResult(True, path, f"{name} is not installed or configured; skipped", skipped=True)


def _write(
    path: Path, transform: Callable[[Optional[str]], Optional[str]], dry_run: bool, label: str, theme: ColorScheme
) -> AdapterResult:
    """Run ``transform`` as a locked update, or as a pure preview in dry-run."""
    if dry_run:
        try:
            current = safe_read_text(path)[0] if path.exists() else None
            new = transform(current)
        except Exception as e:  # noqa: BLE001 - reported to the user
            return AdapterResult(False, path, f"{label}: {e}", error=str(e))
        verb = "keep" if new is None or new == current else "update"
        return AdapterResult(True, path, f"[DRY-RUN] Would {verb} {label} theme '{theme.name}' ({path})")
    try:
        result = atomic_update_text(path, transform)
    except Exception as e:  # noqa: BLE001 - reported to the user
        return AdapterResult(False, path, f"Failed updating {label}: {e}", error=str(e))
    if not result.changed:
        return AdapterResult(True, path, f"{label} already uses '{theme.name}'", skipped=True)
    return AdapterResult(True, path, f"Updated {label} theme to '{theme.name}'")


# ---------------------------------------------------------------------------
# Ghostty: managed block between markers inside the main config
# ---------------------------------------------------------------------------
# Exact shape written by older versions (no markers): removed only on a full
# structural match, never by a loose pattern.
_LEGACY_GHOSTTY = re.compile(
    r"(?m)^# Omarchy theme: [^\n]*\n"
    rf"background = {_HEX}\nforeground = {_HEX}\ncursor-color = {_HEX}\nselection-background = {_HEX}\n"
    rf"(?:palette = (?:[0-9]|1[0-5])={_HEX}\n){{16}}"
)
_MANAGED_BLOCK = re.compile(re.escape(BEGIN_MARK) + r".*?" + re.escape(END_MARK) + r"\n?", re.S)


def _replace_managed_block(current: Optional[str], block: str) -> str:
    text = current or ""
    text = _MANAGED_BLOCK.sub("", text)
    text = _LEGACY_GHOSTTY.sub("", text)
    text = re.sub(r"\n{3,}", "\n\n", text).rstrip("\n")
    managed = f"{BEGIN_MARK}\n{block.rstrip()}\n{END_MARK}\n"
    return f"{text}\n\n{managed}" if text else managed


def sync_ghostty(theme: ColorScheme, config_path: Optional[Path] = None, dry_run: bool = False) -> AdapterResult:
    """Sync theme to Ghostty (managed block at the end of the config)."""
    path = config_path or (config_home() / "ghostty" / "config")
    if config_path is None and not _available("ghostty", path):
        return _skipped(path, "Ghostty")
    block = theme.to_ghostty_config()
    return _write(path, lambda cur: _replace_managed_block(cur, block), dry_run, "Ghostty", theme)


# ---------------------------------------------------------------------------
# Kitty: separate theme file + one idempotent include line
# ---------------------------------------------------------------------------
def sync_kitty(theme: ColorScheme, config_path: Optional[Path] = None, dry_run: bool = False) -> AdapterResult:
    """Sync theme to Kitty (current-theme.conf, included from kitty.conf)."""
    kitty_dir = config_path.parent if config_path else (config_home() / "kitty")
    theme_file = kitty_dir / "current-theme.conf"
    main_conf = kitty_dir / "kitty.conf"
    if config_path is None and not _available("kitty", main_conf, theme_file):
        return _skipped(theme_file, "Kitty")
    include_line = "include current-theme.conf"

    def add_include(cur: Optional[str]) -> Optional[str]:
        text = cur or ""
        if re.search(r"(?m)^\s*include\s+current-theme\.conf\s*$", text):
            return None
        return f"{text.rstrip()}\n\n{include_line}\n" if text.strip() else f"{include_line}\n"

    content = theme.to_kitty_config()
    res = _write(theme_file, lambda _cur: content, dry_run, "Kitty", theme)
    if not res.success or dry_run:
        return res
    inc = _write(main_conf, add_include, dry_run, "Kitty include", theme)
    if not inc.success:
        return inc
    return res


# ---------------------------------------------------------------------------
# Alacritty: separate theme file + one idempotent general.import entry
# ---------------------------------------------------------------------------
_LEGACY_ALACRITTY = re.compile(
    r"(?m)^# Omarchy theme: [^\n]*\n"
    rf'\[colors\.primary\]\nbackground = "{_HEX}"\nforeground = "{_HEX}"\n\n'
    rf'\[colors\.cursor\]\ncursor = "{_HEX}"\ntext = "{_HEX}"\n\n'
    rf'\[colors\.selection\]\nbackground = "{_HEX}"\ntext = "{_HEX}"\n\n'
    rf'\[colors\.normal\]\n(?:(?:black|red|green|yellow|blue|magenta|cyan|white) = "{_HEX}"\n){{8}}\n'
    rf'\[colors\.bright\]\n(?:(?:black|red|green|yellow|blue|magenta|cyan|white) = "{_HEX}"\n){{8}}'
)


def alacritty_theme_toml(theme: ColorScheme) -> str:
    c = theme.to_alacritty_dict()["colors"]
    lines = [f"# Managed by omarchy-theme-sync. Theme: {theme.name}"]
    for table in ("primary", "cursor", "selection", "normal", "bright"):
        lines.append(f"[colors.{table}]")
        for key, value in c[table].items():
            lines.append(f'{key} = "{value}"')
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _import_entry(theme_path: Path) -> str:
    try:
        return "~/" + str(theme_path.relative_to(Path.home()))
    except ValueError:
        return str(theme_path)


def _toml_load(text: str) -> Optional[Dict[str, Any]]:
    if _toml is None:
        return None
    return _toml.loads(text)


def _without_import(data: Dict[str, Any]) -> Dict[str, Any]:
    out = {k: v for k, v in data.items() if k != "import"}
    if isinstance(out.get("general"), dict):
        general = {k: v for k, v in out["general"].items() if k != "import"}
        if general:
            out["general"] = general
        else:
            out.pop("general")
    return out


def _imports(data: Dict[str, Any]) -> List[str]:
    found: List[str] = []
    for value in (data.get("import"), (data.get("general") or {}).get("import")):
        if isinstance(value, list):
            found.extend(str(v) for v in value)
    return found


def _insert_into_array(text: str, start: int, entry: str) -> str:
    """Insert ``entry`` into the TOML array whose ``[`` follows ``start``."""
    open_at = text.index("[", start)
    close_at = text.index("]", open_at)
    inner = text[open_at + 1 : close_at]
    item = f'"{entry}"'
    if "\n" in inner:
        insertion = f'\n  {item},'
        return text[: open_at + 1] + insertion + text[open_at + 1 :]
    if inner.strip():
        return text[:close_at].rstrip() + f", {item}" + text[close_at:]
    return text[: open_at + 1] + item + text[close_at:]


def _add_alacritty_import(current: Optional[str], entry: str) -> Optional[str]:
    """Return alacritty.toml with ``entry`` imported, or None if already there.

    Raises ValueError when the file cannot be edited safely (fail closed).
    """
    text = current or ""
    cleaned = _LEGACY_ALACRITTY.sub("", text)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    if _toml is not None:
        try:
            data = _toml.loads(cleaned)
        except Exception as e:  # noqa: BLE001
            raise ValueError(f"alacritty.toml is not valid TOML ({e}); not modified") from e
        if entry in _imports(data):
            return cleaned if cleaned != text else None
    else:
        data = None
        if entry in cleaned:
            return cleaned if cleaned != text else None

    item = f'"{entry}"'
    general_hdr = re.search(r"(?m)^[ \t]*\[general\][ \t]*(#.*)?$", cleaned)
    if general_hdr:
        nxt = re.search(r"(?m)^[ \t]*\[", cleaned[general_hdr.end():])
        section_end = general_hdr.end() + (nxt.start() if nxt else len(cleaned) - general_hdr.end())
        imp = re.search(r"(?m)^[ \t]*import[ \t]*=[ \t]*\[", cleaned[general_hdr.end():section_end])
        if imp:
            new = _insert_into_array(cleaned, general_hdr.end() + imp.start(), entry)
        else:
            new = cleaned[: general_hdr.end()] + f"\nimport = [{item}]" + cleaned[general_hdr.end():]
    else:
        first_table = re.search(r"(?m)^[ \t]*\[", cleaned)
        head = cleaned[: first_table.start()] if first_table else cleaned
        top_imp = re.search(r"(?m)^[ \t]*import[ \t]*=[ \t]*\[", head)
        if top_imp:
            new = _insert_into_array(cleaned, top_imp.start(), entry)
        elif data is not None and "general" in data:
            # `general` exists as dotted keys: extend it the same way.
            new = f"general.import = [{item}]\n" + cleaned
        elif data is None and re.search(r"(?m)^[ \t]*(general\.|import\b)", cleaned):
            raise ValueError("cannot verify alacritty.toml without tomllib; add the import manually")
        else:
            new = (cleaned.rstrip("\n") + "\n\n" if cleaned.strip() else "") + f"[general]\nimport = [{item}]\n"

    if _toml is not None:
        try:
            new_data = _toml.loads(new)
        except Exception as e:  # noqa: BLE001
            raise ValueError(f"refusing an edit that would break alacritty.toml ({e})") from e
        if entry not in _imports(new_data) or _without_import(new_data) != _without_import(data or {}):
            raise ValueError("refusing an edit that would change other alacritty.toml settings")
    return new


def sync_alacritty(theme: ColorScheme, config_path: Optional[Path] = None, dry_run: bool = False) -> AdapterResult:
    """Sync theme to Alacritty: write omarchy-theme.toml and import it.

    The user's alacritty.toml keeps every table it had ([[keyboard.bindings]],
    [colors.*], ...); only one import entry is added. Colors defined directly
    in alacritty.toml still win over the imported theme (Alacritty loads
    imports first).
    """
    path = config_path or (config_home() / "alacritty" / "alacritty.toml")
    theme_path = path.with_name(ALACRITTY_THEME_FILE)
    if config_path is None and not _available("alacritty", path, theme_path):
        return _skipped(path, "Alacritty")
    entry = _import_entry(theme_path)

    if dry_run:
        try:
            current = safe_read_text(path)[0] if path.exists() else None
            _add_alacritty_import(current, entry)
        except Exception as e:  # noqa: BLE001
            return AdapterResult(False, path, f"Alacritty: {e}", error=str(e))
        return AdapterResult(True, path, f"[DRY-RUN] Would write {theme_path.name} and import it from {path.name}")

    res = _write(theme_path, lambda _cur: alacritty_theme_toml(theme), False, "Alacritty", theme)
    if not res.success:
        return res
    inc = _write(path, lambda cur: _add_alacritty_import(cur, entry), False, "Alacritty import", theme)
    if not inc.success:
        return inc
    note = ""
    if path.exists():
        try:
            data = _toml_load(safe_read_text(path)[0]) or {}
        except Exception:  # noqa: BLE001
            data = {}
        if isinstance(data.get("colors"), dict):
            note = " (alacritty.toml defines its own [colors]; those override the imported theme)"
    return AdapterResult(True, theme_path, res.message + note, skipped=res.skipped and inc.skipped)


def sync_all_linux_terminals(theme: ColorScheme, dry_run: bool = False) -> List[AdapterResult]:
    """Sync theme to every installed or already configured Linux terminal."""
    return [
        sync_ghostty(theme, dry_run=dry_run),
        sync_kitty(theme, dry_run=dry_run),
        sync_alacritty(theme, dry_run=dry_run),
    ]
