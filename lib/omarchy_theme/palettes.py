"""Standard Omarchy palettes and external theme file loader."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional

try:
    import tomllib  # Python 3.11+
except ImportError:
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        tomllib = None  # type: ignore

from omarchy_theme.models import ColorScheme

# -----------------------------------------------------------------------------
# Canonical Theme Definitions
# -----------------------------------------------------------------------------

TOKYO_NIGHT = ColorScheme(
    name="Tokyo Night",
    background="#1a1b26",
    foreground="#c0caf5",
    cursor_color="#c0caf5",
    selection_background="#283457",
    black="#15161e",
    red="#f7768e",
    green="#9ece6a",
    yellow="#e0af68",
    blue="#7aa2f7",
    purple="#bb9af7",
    cyan="#7dcfff",
    white="#a9b1d6",
    bright_black="#414868",
    bright_red="#f7768e",
    bright_green="#9ece6a",
    bright_yellow="#e0af68",
    bright_blue="#7aa2f7",
    bright_purple="#bb9af7",
    bright_cyan="#7dcfff",
    bright_white="#c0caf5",
    vscode_theme_name="Tokyo Night",
    is_dark=True,
)

TOKYO_NIGHT_STORM = ColorScheme(
    name="Tokyo Night Storm",
    background="#24283b",
    foreground="#c0caf5",
    cursor_color="#c0caf5",
    selection_background="#2e3c64",
    black="#1d202f",
    red="#f7768e",
    green="#9ece6a",
    yellow="#e0af68",
    blue="#7aa2f7",
    purple="#bb9af7",
    cyan="#7dcfff",
    white="#a9b1d6",
    bright_black="#414868",
    bright_red="#f7768e",
    bright_green="#9ece6a",
    bright_yellow="#e0af68",
    bright_blue="#7aa2f7",
    bright_purple="#bb9af7",
    bright_cyan="#7dcfff",
    bright_white="#c0caf5",
    vscode_theme_name="Tokyo Night Storm",
    is_dark=True,
)

CATPPUCCIN_MOCHA = ColorScheme(
    name="Catppuccin Mocha",
    background="#1e1e2e",
    foreground="#cdd6f4",
    cursor_color="#f5e0dc",
    selection_background="#585b70",
    black="#45475a",
    red="#f38ba8",
    green="#a6e3a1",
    yellow="#f9e2af",
    blue="#89b4fa",
    purple="#cba6f7",
    cyan="#94e2d5",
    white="#bac2de",
    bright_black="#585b70",
    bright_red="#f38ba8",
    bright_green="#a6e3a1",
    bright_yellow="#f9e2af",
    bright_blue="#89b4fa",
    bright_purple="#cba6f7",
    bright_cyan="#94e2d5",
    bright_white="#a6adc8",
    vscode_theme_name="Catppuccin Mocha",
    is_dark=True,
)

CATPPUCCIN_MACCHIATO = ColorScheme(
    name="Catppuccin Macchiato",
    background="#24273a",
    foreground="#cad3f5",
    cursor_color="#f4dbd6",
    selection_background="#5b6078",
    black="#494d64",
    red="#ed8796",
    green="#a6da95",
    yellow="#eed49f",
    blue="#8aadf4",
    purple="#c6a0f6",
    cyan="#8bd5ca",
    white="#b8c0e0",
    bright_black="#5b6078",
    bright_red="#ed8796",
    bright_green="#a6da95",
    bright_yellow="#eed49f",
    bright_blue="#8aadf4",
    bright_purple="#c6a0f6",
    bright_cyan="#8bd5ca",
    bright_white="#a5adcb",
    vscode_theme_name="Catppuccin Macchiato",
    is_dark=True,
)

CATPPUCCIN_FRAPPE = ColorScheme(
    name="Catppuccin Frappe",
    background="#303446",
    foreground="#c6d0f5",
    cursor_color="#f2d5cf",
    selection_background="#626880",
    black="#51576d",
    red="#e78284",
    green="#a6d189",
    yellow="#e5c890",
    blue="#8caaee",
    purple="#ca9ee6",
    cyan="#81c8be",
    white="#b5bfe2",
    bright_black="#626880",
    bright_red="#e78284",
    bright_green="#a6d189",
    bright_yellow="#e5c890",
    bright_blue="#8caaee",
    bright_purple="#ca9ee6",
    bright_cyan="#81c8be",
    bright_white="#a5adce",
    vscode_theme_name="Catppuccin Frappe",
    is_dark=True,
)

CATPPUCCIN_LATTE = ColorScheme(
    name="Catppuccin Latte",
    background="#eff1f5",
    foreground="#4c4f69",
    cursor_color="#dc8a78",
    selection_background="#acb0be",
    black="#5c5f77",
    red="#d20f39",
    green="#40a02b",
    yellow="#df8e1d",
    blue="#1e66f5",
    purple="#8839ef",
    cyan="#179299",
    white="#bcc0cc",
    bright_black="#6c6f85",
    bright_red="#d20f39",
    bright_green="#40a02b",
    bright_yellow="#df8e1d",
    bright_blue="#1e66f5",
    bright_purple="#8839ef",
    bright_cyan="#179299",
    bright_white="#acb0be",
    vscode_theme_name="Catppuccin Latte",
    is_dark=False,
)

NORD = ColorScheme(
    name="Nord",
    background="#2e3440",
    foreground="#d8dee9",
    cursor_color="#d8dee9",
    selection_background="#434c5e",
    black="#3b4252",
    red="#bf616a",
    green="#a3be8c",
    yellow="#ebcb8b",
    blue="#81a1c1",
    purple="#b48ead",
    cyan="#88c0d0",
    white="#e5e9f0",
    bright_black="#4c566a",
    bright_red="#bf616a",
    bright_green="#a3be8c",
    bright_yellow="#ebcb8b",
    bright_blue="#81a1c1",
    bright_purple="#b48ead",
    bright_cyan="#8fbcbb",
    bright_white="#eceff4",
    vscode_theme_name="Nord",
    is_dark=True,
)

DRACULA = ColorScheme(
    name="Dracula",
    background="#282a36",
    foreground="#f8f8f2",
    cursor_color="#f8f8f2",
    selection_background="#44475a",
    black="#21222c",
    red="#ff5555",
    green="#50fa7b",
    yellow="#f1fa8c",
    blue="#bd93f9",
    purple="#ff79c6",
    cyan="#8be9fd",
    white="#f8f8f2",
    bright_black="#6272a4",
    bright_red="#ff6e6e",
    bright_green="#69ff94",
    bright_yellow="#ffffa5",
    bright_blue="#d6acff",
    bright_purple="#ff92df",
    bright_cyan="#a4ffff",
    bright_white="#ffffff",
    vscode_theme_name="Dracula",
    is_dark=True,
)

GRUVBOX_DARK = ColorScheme(
    name="Gruvbox Dark",
    background="#282828",
    foreground="#ebdbb2",
    cursor_color="#ebdbb2",
    selection_background="#504945",
    black="#282828",
    red="#cc241d",
    green="#98971a",
    yellow="#d79921",
    blue="#458588",
    purple="#b16286",
    cyan="#689d6a",
    white="#a89984",
    bright_black="#928374",
    bright_red="#fb4934",
    bright_green="#b8bb26",
    bright_yellow="#fabd2f",
    bright_blue="#83a598",
    bright_purple="#d3869b",
    bright_cyan="#8ec07c",
    bright_white="#ebdbb2",
    vscode_theme_name="Gruvbox Dark Medium",
    is_dark=True,
)

ONE_DARK = ColorScheme(
    name="One Dark",
    background="#282c34",
    foreground="#abb2bf",
    cursor_color="#528bff",
    selection_background="#3e4451",
    black="#282c34",
    red="#e06c75",
    green="#98c379",
    yellow="#e5c07b",
    blue="#61afef",
    purple="#c678dd",
    cyan="#56b6c2",
    white="#abb2bf",
    bright_black="#5c6370",
    bright_red="#e06c75",
    bright_green="#98c379",
    bright_yellow="#e5c07b",
    bright_blue="#61afef",
    bright_purple="#c678dd",
    bright_cyan="#56b6c2",
    bright_white="#ffffff",
    vscode_theme_name="One Dark Pro",
    is_dark=True,
)

SOLARIZED_DARK = ColorScheme(
    name="Solarized Dark",
    background="#002b36",
    foreground="#839496",
    cursor_color="#93a1a1",
    selection_background="#073642",
    black="#073642",
    red="#dc322f",
    green="#859900",
    yellow="#b58900",
    blue="#268bd2",
    purple="#d33682",
    cyan="#2aa198",
    white="#eee8d5",
    bright_black="#002b36",
    bright_red="#cb4b16",
    bright_green="#586e75",
    bright_yellow="#657b83",
    bright_blue="#839496",
    bright_purple="#6c71c4",
    bright_cyan="#93a1a1",
    bright_white="#fdf6e3",
    vscode_theme_name="Solarized Dark",
    is_dark=True,
)

BUILTIN_PALETTES: Dict[str, ColorScheme] = {
    "tokyo-night": TOKYO_NIGHT,
    "tokyo-night-storm": TOKYO_NIGHT_STORM,
    "catppuccin-mocha": CATPPUCCIN_MOCHA,
    "catppuccin-macchiato": CATPPUCCIN_MACCHIATO,
    "catppuccin-frappe": CATPPUCCIN_FRAPPE,
    "catppuccin-latte": CATPPUCCIN_LATTE,
    "nord": NORD,
    "dracula": DRACULA,
    "gruvbox-dark": GRUVBOX_DARK,
    "one-dark": ONE_DARK,
    "solarized-dark": SOLARIZED_DARK,
}


def normalize_palette_name(name: str) -> str:
    """Normalize user input name to lookup key (e.g. 'Tokyo Night' -> 'tokyo-night')."""
    return name.strip().lower().replace("_", "-").replace(" ", "-")


def get_builtin_palette(name: str) -> Optional[ColorScheme]:
    """Retrieve built-in palette by case-insensitive name or variant."""
    key = normalize_palette_name(name)
    if key in BUILTIN_PALETTES:
        return BUILTIN_PALETTES[key]

    # Aliases
    aliases = {
        "catppuccin": "catppuccin-mocha",
        "tokyo": "tokyo-night",
        "gruvbox": "gruvbox-dark",
        "solarized": "solarized-dark",
    }
    alias_key = aliases.get(key)
    if alias_key and alias_key in BUILTIN_PALETTES:
        return BUILTIN_PALETTES[alias_key]

    return None


def list_builtin_palettes() -> List[str]:
    """Return sorted list of built-in palette identifiers."""
    return sorted(BUILTIN_PALETTES.keys())


def load_palette_from_file(file_path: Path | str) -> ColorScheme:
    """Load color scheme from a .toml or .json file."""
    path = Path(file_path)
    if not path.is_file():
        raise FileNotFoundError(f"Theme file not found: {path}")

    text = path.read_text(encoding="utf-8")
    suffix = path.suffix.lower()

    if suffix in (".toml", ".tml"):
        if tomllib is None:
            raise RuntimeError("TOML parser not available. Python 3.11+ or 'tomli' package required.")
        data = tomllib.loads(text)
    elif suffix in (".json", ".jsonc"):
        # Strip simple comments if JSON file
        data = json.loads(text)
    else:
        # Try JSON first, then TOML
        try:
            data = json.loads(text)
        except Exception:
            if tomllib is not None:
                data = tomllib.loads(text)
            else:
                raise ValueError(f"Unrecognized file format for theme: {path}")

    if not isinstance(data, dict):
        raise ValueError(f"Invalid theme file structure in {path}: expected root object")

    if "name" not in data and "title" not in data:
        data["name"] = path.stem.replace("-", " ").replace("_", " ").title()

    return ColorScheme.from_dict(data)
