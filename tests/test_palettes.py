"""Tests for palette catalog and cross-format color schema conversion."""

from __future__ import annotations

import tempfile
from pathlib import Path
import pytest

from omarchy_theme.models import ColorScheme, normalize_hex
from omarchy_theme.palettes import (
    BUILTIN_PALETTES,
    CATPPUCCIN_LATTE,
    CATPPUCCIN_MOCHA,
    NORD,
    TOKYO_NIGHT,
    get_builtin_palette,
    load_palette_from_file,
)


def test_normalize_hex() -> None:
    assert normalize_hex("#fff") == "#ffffff"
    assert normalize_hex("1a1b26") == "#1a1b26"
    assert normalize_hex("#1A1B26") == "#1a1b26"
    assert normalize_hex("#1a1b26ff") == "#1a1b26"  # alpha stripped

    with pytest.raises(ValueError):
        normalize_hex("not-a-color")
    with pytest.raises(ValueError):
        normalize_hex("#12345")


def test_builtin_palettes_exist() -> None:
    assert "tokyo-night" in BUILTIN_PALETTES
    assert "catppuccin-mocha" in BUILTIN_PALETTES
    assert "nord" in BUILTIN_PALETTES

    assert get_builtin_palette("Tokyo Night") == TOKYO_NIGHT
    assert get_builtin_palette("tokyo_night") == TOKYO_NIGHT
    assert get_builtin_palette("catppuccin") == CATPPUCCIN_MOCHA
    assert get_builtin_palette("Catppuccin Latte") == CATPPUCCIN_LATTE


def test_windows_terminal_schema_conformance() -> None:
    wt_dict = TOKYO_NIGHT.to_windows_terminal_dict()

    # Crucial schema checks
    assert "purple" in wt_dict, "Windows Terminal requires 'purple', not 'magenta'"
    assert "brightPurple" in wt_dict, "Windows Terminal requires 'brightPurple', not 'brightMagenta'"
    assert "magenta" not in wt_dict
    assert "brightMagenta" not in wt_dict

    # Required WT properties
    required_keys = {
        "name", "background", "foreground", "cursorColor", "selectionBackground",
        "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
        "brightPurple", "brightCyan", "brightWhite",
    }
    assert required_keys.issubset(set(wt_dict.keys()))

    # Verify Tokyo Night specific colors
    assert wt_dict["background"] == "#1a1b26"
    assert wt_dict["foreground"] == "#c0caf5"
    assert wt_dict["purple"] == "#bb9af7"


def test_vscode_color_customizations() -> None:
    vsc_dict = NORD.to_vscode_color_customizations()

    # VS Code terminal uses ansiMagenta
    assert "terminal.ansiMagenta" in vsc_dict
    assert "terminal.ansiBrightMagenta" in vsc_dict
    assert vsc_dict["terminal.background"] == "#2e3440"
    assert vsc_dict["terminal.foreground"] == "#d8dee9"


def test_alacritty_and_ghostty_conversions() -> None:
    alac = CATPPUCCIN_MOCHA.to_alacritty_dict()
    assert alac["colors"]["primary"]["background"] == "#1e1e2e"
    assert alac["colors"]["normal"]["magenta"] == "#cba6f7"

    ghostty = NORD.to_ghostty_config()
    assert "background = #2e3440" in ghostty
    assert "palette = 5=#b48ead" in ghostty


def test_load_external_json_theme() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        theme_file = Path(tmp_dir) / "custom.json"
        theme_file.write_text(
            """{
                "name": "Custom Theme",
                "background": "#000000",
                "foreground": "#ffffff",
                "cursorColor": "#ffffff",
                "selectionBackground": "#333333",
                "black": "#000000",
                "red": "#ff0000",
                "green": "#00ff00",
                "yellow": "#ffff00",
                "blue": "#0000ff",
                "purple": "#ff00ff",
                "cyan": "#00ffff",
                "white": "#ffffff",
                "brightBlack": "#555555",
                "brightRed": "#ff5555",
                "brightGreen": "#55ff55",
                "brightYellow": "#ffff55",
                "brightBlue": "#5555ff",
                "brightPurple": "#ff55ff",
                "brightCyan": "#55ffff",
                "brightWhite": "#ffffff"
            }""",
            encoding="utf-8",
        )

        loaded = load_palette_from_file(theme_file)
        assert loaded.name == "Custom Theme"
        assert loaded.background == "#000000"
        assert loaded.purple == "#ff00ff"
