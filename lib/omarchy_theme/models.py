"""Color scheme models and cross-format conversion engines.

Converts between Omarchy palettes, Windows Terminal JSON schema,
VS Code terminal color customizations, and Linux terminal formats.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, Optional


def normalize_hex(color_str: str) -> str:
    """Normalize a hex color string to lowercase #rrggbb format.

    Supports #rgb, #rrggbb, rgb, rrggbb, and rgba (alpha truncated).
    Raises ValueError on malformed hex strings.
    """
    if not isinstance(color_str, str):
        raise ValueError(f"Color value must be a string, got {type(color_str).__name__}: {color_str!r}")

    cleaned = color_str.strip().lstrip("#").lower()

    if len(cleaned) == 3:
        # #rgb -> #rrggbb
        cleaned = "".join(c * 2 for c in cleaned)
    elif len(cleaned) == 4:
        # #rgba -> #rrggbb (drop alpha)
        cleaned = "".join(c * 2 for c in cleaned[:3])
    elif len(cleaned) == 8:
        # #rrggbbaa -> #rrggbb (drop alpha)
        cleaned = cleaned[:6]

    if len(cleaned) != 6 or not re.fullmatch(r"[0-9a-f]{6}", cleaned):
        raise ValueError(f"Invalid hex color string: {color_str!r}")

    return f"#{cleaned}"


@dataclass
class ColorScheme:
    """Canonical cross-OS color scheme specification."""

    name: str
    background: str
    foreground: str
    cursor_color: str
    selection_background: str

    # ANSI Normal 0-7
    black: str
    red: str
    green: str
    yellow: str
    blue: str
    purple: str  # ANSI 5 (Magenta)
    cyan: str
    white: str

    # ANSI Bright 8-15
    bright_black: str
    bright_red: str
    bright_green: str
    bright_yellow: str
    bright_blue: str
    bright_purple: str  # ANSI 13 (Bright Magenta)
    bright_cyan: str
    bright_white: str

    # Optional metadata
    selection_foreground: Optional[str] = None
    vscode_theme_name: Optional[str] = None
    is_dark: bool = True
    metadata: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        """Validate and normalize all color codes."""
        if not self.name or not self.name.strip():
            raise ValueError("Theme name must not be empty.")

        self.background = normalize_hex(self.background)
        self.foreground = normalize_hex(self.foreground)
        self.cursor_color = normalize_hex(self.cursor_color)
        self.selection_background = normalize_hex(self.selection_background)

        self.black = normalize_hex(self.black)
        self.red = normalize_hex(self.red)
        self.green = normalize_hex(self.green)
        self.yellow = normalize_hex(self.yellow)
        self.blue = normalize_hex(self.blue)
        self.purple = normalize_hex(self.purple)
        self.cyan = normalize_hex(self.cyan)
        self.white = normalize_hex(self.white)

        self.bright_black = normalize_hex(self.bright_black)
        self.bright_red = normalize_hex(self.bright_red)
        self.bright_green = normalize_hex(self.bright_green)
        self.bright_yellow = normalize_hex(self.bright_yellow)
        self.bright_blue = normalize_hex(self.bright_blue)
        self.bright_purple = normalize_hex(self.bright_purple)
        self.bright_cyan = normalize_hex(self.bright_cyan)
        self.bright_white = normalize_hex(self.bright_white)

        if self.selection_foreground:
            self.selection_foreground = normalize_hex(self.selection_foreground)

    # -------------------------------------------------------------------------
    # Target Conversions
    # -------------------------------------------------------------------------

    def to_windows_terminal_dict(self) -> Dict[str, str]:
        """Convert to Windows Terminal color scheme JSON schema.

        Windows Terminal requires:
        - 'purple' instead of 'magenta'
        - 'brightPurple' instead of 'brightMagenta'
        - 'cursorColor' and 'selectionBackground'
        """
        wt_scheme: Dict[str, str] = {
            "name": self.name,
            "cursorColor": self.cursor_color,
            "selectionBackground": self.selection_background,
            "background": self.background,
            "foreground": self.foreground,
            "black": self.black,
            "blue": self.blue,
            "cyan": self.cyan,
            "green": self.green,
            "purple": self.purple,
            "red": self.red,
            "white": self.white,
            "yellow": self.yellow,
            "brightBlack": self.bright_black,
            "brightBlue": self.bright_blue,
            "brightCyan": self.bright_cyan,
            "brightGreen": self.bright_green,
            "brightPurple": self.bright_purple,
            "brightRed": self.bright_red,
            "brightWhite": self.bright_white,
            "brightYellow": self.bright_yellow,
        }
        if self.selection_foreground:
            wt_scheme["selectionForeground"] = self.selection_foreground
        return wt_scheme

    def to_vscode_color_customizations(self) -> Dict[str, str]:
        """Convert to VS Code terminal colorCustomizations dictionary.

        Maps to terminal.ansi* tokens so integrated terminal colors are
        automatically themed without requiring external theme extensions.
        """
        customizations: Dict[str, str] = {
            "terminal.background": self.background,
            "terminal.foreground": self.foreground,
            "terminalCursor.foreground": self.cursor_color,
            "terminal.selectionBackground": self.selection_background,
            "terminal.ansiBlack": self.black,
            "terminal.ansiRed": self.red,
            "terminal.ansiGreen": self.green,
            "terminal.ansiYellow": self.yellow,
            "terminal.ansiBlue": self.blue,
            "terminal.ansiMagenta": self.purple,  # VS Code uses Magenta
            "terminal.ansiCyan": self.cyan,
            "terminal.ansiWhite": self.white,
            "terminal.ansiBrightBlack": self.bright_black,
            "terminal.ansiBrightRed": self.bright_red,
            "terminal.ansiBrightGreen": self.bright_green,
            "terminal.ansiBrightYellow": self.bright_yellow,
            "terminal.ansiBrightBlue": self.bright_blue,
            "terminal.ansiBrightMagenta": self.bright_purple,
            "terminal.ansiBrightCyan": self.bright_cyan,
            "terminal.ansiBrightWhite": self.bright_white,
        }
        if self.selection_foreground:
            customizations["terminal.selectionForeground"] = self.selection_foreground
        return customizations

    def to_alacritty_dict(self) -> Dict[str, Any]:
        """Convert to Alacritty TOML color configuration structure."""
        return {
            "colors": {
                "primary": {
                    "background": self.background,
                    "foreground": self.foreground,
                },
                "cursor": {
                    "text": self.background,
                    "cursor": self.cursor_color,
                },
                "selection": {
                    "text": self.foreground,
                    "background": self.selection_background,
                },
                "normal": {
                    "black": self.black,
                    "red": self.red,
                    "green": self.green,
                    "yellow": self.yellow,
                    "blue": self.blue,
                    "magenta": self.purple,
                    "cyan": self.cyan,
                    "white": self.white,
                },
                "bright": {
                    "black": self.bright_black,
                    "red": self.bright_red,
                    "green": self.bright_green,
                    "yellow": self.bright_yellow,
                    "blue": self.bright_blue,
                    "magenta": self.bright_purple,
                    "cyan": self.bright_cyan,
                    "white": self.bright_white,
                },
            }
        }

    def to_ghostty_config(self) -> str:
        """Convert to Ghostty terminal configuration snippet."""
        lines = [
            f"# Omarchy theme: {self.name}",
            f"background = {self.background}",
            f"foreground = {self.foreground}",
            f"cursor-color = {self.cursor_color}",
            f"selection-background = {self.selection_background}",
            f"palette = 0={self.black}",
            f"palette = 1={self.red}",
            f"palette = 2={self.green}",
            f"palette = 3={self.yellow}",
            f"palette = 4={self.blue}",
            f"palette = 5={self.purple}",
            f"palette = 6={self.cyan}",
            f"palette = 7={self.white}",
            f"palette = 8={self.bright_black}",
            f"palette = 9={self.bright_red}",
            f"palette = 10={self.bright_green}",
            f"palette = 11={self.bright_yellow}",
            f"palette = 12={self.bright_blue}",
            f"palette = 13={self.bright_purple}",
            f"palette = 14={self.bright_cyan}",
            f"palette = 15={self.bright_white}",
        ]
        return "\n".join(lines) + "\n"

    def to_kitty_config(self) -> str:
        """Convert to Kitty terminal configuration snippet."""
        lines = [
            f"# Omarchy theme: {self.name}",
            f"foreground            {self.foreground}",
            f"background            {self.background}",
            f"selection_foreground   {self.selection_foreground or self.foreground}",
            f"selection_background   {self.selection_background}",
            f"cursor                {self.cursor_color}",
            f"color0  {self.black}",
            f"color1  {self.red}",
            f"color2  {self.green}",
            f"color3  {self.yellow}",
            f"color4  {self.blue}",
            f"color5  {self.purple}",
            f"color6  {self.cyan}",
            f"color7  {self.white}",
            f"color8  {self.bright_black}",
            f"color9  {self.bright_red}",
            f"color10 {self.bright_green}",
            f"color11 {self.bright_yellow}",
            f"color12 {self.bright_blue}",
            f"color13 {self.bright_purple}",
            f"color14 {self.bright_cyan}",
            f"color15 {self.bright_white}",
        ]
        return "\n".join(lines) + "\n"

    # -------------------------------------------------------------------------
    # Ingestion Parsers
    # -------------------------------------------------------------------------

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> ColorScheme:
        """Parse color scheme from arbitrary dictionary format (WT, Alacritty, or flat)."""
        name = data.get("name") or data.get("title") or "Unnamed Scheme"

        # Check for nested Alacritty/Omarchy structure
        raw_colors = data.get("colors")
        colors_block: Dict[str, Any] = raw_colors if isinstance(raw_colors, dict) else (data if isinstance(data, dict) else {})

        normal_val = colors_block.get("normal")
        normal: Dict[str, Any] = normal_val if isinstance(normal_val, dict) else {}

        bright_val = colors_block.get("bright")
        bright: Dict[str, Any] = bright_val if isinstance(bright_val, dict) else {}

        primary_val = colors_block.get("primary")
        primary: Dict[str, Any] = primary_val if isinstance(primary_val, dict) else {}

        cursor_val = colors_block.get("cursor")
        cursor: Dict[str, Any] = cursor_val if isinstance(cursor_val, dict) else {}

        selection_val = colors_block.get("selection")
        selection: Dict[str, Any] = selection_val if isinstance(selection_val, dict) else {}

        def resolve(key: str, *fallbacks: Any) -> str:
            # Look in flat root first
            for k in [key, *fallbacks]:
                if isinstance(k, str):
                    val = colors_block.get(k)
                    if isinstance(val, str):
                        return val
                    data_val = data.get(k) if isinstance(data, dict) else None
                    if isinstance(data_val, str):
                        return data_val
            raise KeyError(f"Missing required color definition for {key!r}")

        bg_val = primary.get("background")
        bg: str = bg_val if isinstance(bg_val, str) else resolve("background", "bg")

        fg_val = primary.get("foreground")
        fg: str = fg_val if isinstance(fg_val, str) else resolve("foreground", "fg")

        cur_candidate = cursor.get("cursor") if isinstance(cursor, dict) else None
        cur: str = cur_candidate if isinstance(cur_candidate, str) else resolve("cursorColor", "cursor_color", "cursor", fg)

        sel_candidate = selection.get("background") if isinstance(selection, dict) else None
        sel: str = sel_candidate if isinstance(sel_candidate, str) else resolve("selectionBackground", "selection_background", "selection", bg)

        def get_c(d: Dict[str, Any], k: str, *alt: str) -> str:
            v = d.get(k)
            if isinstance(v, str):
                return v
            return resolve(k, *alt)

        black = get_c(normal, "black", "color0")
        red = get_c(normal, "red", "color1")
        green = get_c(normal, "green", "color2")
        yellow = get_c(normal, "yellow", "color3")
        blue = get_c(normal, "blue", "color4")
        purple = get_c(normal, "purple", "magenta", "color5")
        cyan = get_c(normal, "cyan", "color6")
        white = get_c(normal, "white", "color7")

        bright_black = get_c(bright, "black", "brightBlack", "bright_black", "color8", black)
        bright_red = get_c(bright, "red", "brightRed", "bright_red", "color9", red)
        bright_green = get_c(bright, "green", "brightGreen", "bright_green", "color10", green)
        bright_yellow = get_c(bright, "yellow", "brightYellow", "bright_yellow", "color11", yellow)
        bright_blue = get_c(bright, "blue", "brightBlue", "bright_blue", "color12", blue)
        bright_purple = get_c(bright, "purple", "brightPurple", "bright_purple", "brightMagenta", "bright_magenta", "color13", purple)
        bright_cyan = get_c(bright, "cyan", "brightCyan", "bright_cyan", "color14", cyan)
        bright_white = get_c(bright, "white", "brightWhite", "bright_white", "color15", white)

        selection_fg: Optional[str] = (
            selection.get("text")
            if isinstance(selection, dict) and selection.get("text")
            else (colors_block.get("selectionForeground") or colors_block.get("selection_foreground"))
        )

        vscode_theme = data.get("vscode_theme_name") or data.get("vscodeTheme")

        return cls(
            name=name,
            background=bg,
            foreground=fg,
            cursor_color=cur,
            selection_background=sel,
            black=black,
            red=red,
            green=green,
            yellow=yellow,
            blue=blue,
            purple=purple,
            cyan=cyan,
            white=white,
            bright_black=bright_black,
            bright_red=bright_red,
            bright_green=bright_green,
            bright_yellow=bright_yellow,
            bright_blue=bright_blue,
            bright_purple=bright_purple,
            bright_cyan=bright_cyan,
            bright_white=bright_white,
            selection_foreground=selection_fg,
            vscode_theme_name=vscode_theme,
            is_dark=data.get("is_dark", True),
        )
