"""Tests for bulletproof JSONC parser, tokenizer, and surgical modifier."""

from __future__ import annotations

import json
import pytest

from omarchy_theme.jsonc import (
    JsoncModifier,
    JsoncParseError,
    parse_jsonc,
    tokenize_jsonc,
)


def test_tokenize_primitives_and_escapes() -> None:
    text = r'{"url": "https://example.com/test", "escaped": "\"//not a comment\""}'
    tokens = tokenize_jsonc(text)
    meaningful = [t for t in tokens if t.kind not in ("WS", "COMMENT")]
    assert len(meaningful) == 9  # {, "url", :, "https...", ,, "escaped", :, "\"...", }


def test_parse_comments_and_trailing_commas() -> None:
    jsonc_text = """// Header comment
    {
        /* Block comment
           multiline */
        "string": "hello // world",
        "number": 42,
        "pi": 3.1415,
        "bool": true,
        "nil": null,
        "list": [
            1,
            2, // inline comment
            3, // trailing comma in array:
        ],
        // Trailing comma in object:
        "nested": {
            "a": "b",
        },
    }
    // Trailing EOF comment
    """
    data = parse_jsonc(jsonc_text)
    assert data["string"] == "hello // world"
    assert data["number"] == 42
    assert data["pi"] == 3.1415
    assert data["bool"] is True
    assert data["nil"] is None
    assert data["list"] == [1, 2, 3]
    assert data["nested"] == {"a": "b"}


def test_parse_bom_handling() -> None:
    bom_text = '\ufeff{"bom": true}'
    data = parse_jsonc(bom_text)
    assert data == {"bom": True}


def test_parse_syntax_error_reporting() -> None:
    invalid = '{\n  "key": "value",\n  "broken": \n}'
    with pytest.raises(JsoncParseError) as exc_info:
        parse_jsonc(invalid)
    assert "Line 4" in str(exc_info.value) or "Line 3" in str(exc_info.value)


def test_surgical_upsert_scheme_preserves_comments() -> None:
    original = """// Critical user comment on line 1
    {
        "$schema": "https://aka.ms/terminal-profiles-schema",
        // Note: do not delete this profile comment
        "profiles": {
            "defaults": {},
            "list": [
                {
                    "name": "Omarchy",
                    "source": "Windows.Terminal.Wsl"
                }
            ]
        },
        "schemes": [
            // Comment inside schemes
            {
                "name": "ExistingTheme",
                "background": "#000000"
            }
        ]
    }
    // Final footer comment
    """

    modifier = JsoncModifier(original)
    new_scheme = {
        "name": "Tokyo Night",
        "background": "#1a1b26",
        "foreground": "#c0caf5",
        "cursorColor": "#c0caf5",
        "selectionBackground": "#283457",
        "black": "#15161e",
        "red": "#f7768e",
        "green": "#9ece6a",
        "yellow": "#e0af68",
        "blue": "#7aa2f7",
        "purple": "#bb9af7",
        "cyan": "#7dcfff",
        "white": "#a9b1d6",
        "brightBlack": "#414868",
        "brightRed": "#f7768e",
        "brightGreen": "#9ece6a",
        "brightYellow": "#e0af68",
        "brightBlue": "#7aa2f7",
        "brightPurple": "#bb9af7",
        "brightCyan": "#7dcfff",
        "brightWhite": "#c0caf5",
    }

    updated = modifier.upsert_windows_terminal_scheme(new_scheme)
    updated = modifier.set_profile_color_scheme("Tokyo Night", profile_name="Omarchy")

    # Assert comments are preserved
    assert "// Critical user comment on line 1" in updated
    assert "// Note: do not delete this profile comment" in updated
    assert "// Comment inside schemes" in updated
    assert "// Final footer comment" in updated

    # Assert new scheme exists and old scheme remains
    parsed = parse_jsonc(updated)
    scheme_names = [s["name"] for s in parsed["schemes"]]
    assert "ExistingTheme" in scheme_names
    assert "Tokyo Night" in scheme_names

    # Assert profile updated
    omarchy_prof = next(p for p in parsed["profiles"]["list"] if p["name"] == "Omarchy")
    assert omarchy_prof["colorScheme"] == "Tokyo Night"


def test_surgical_update_existing_scheme_in_place() -> None:
    original = """{
        "schemes": [
            {
                "name": "Tokyo Night",
                "background": "#000000" // Old bg
            }
        ]
    }"""
    modifier = JsoncModifier(original)
    updated_scheme = {
        "name": "Tokyo Night",
        "background": "#1a1b26",
        "foreground": "#c0caf5",
        "cursorColor": "#c0caf5",
        "selectionBackground": "#283457",
        "black": "#15161e",
        "red": "#f7768e",
        "green": "#9ece6a",
        "yellow": "#e0af68",
        "blue": "#7aa2f7",
        "purple": "#bb9af7",
        "cyan": "#7dcfff",
        "white": "#a9b1d6",
        "brightBlack": "#414868",
        "brightRed": "#f7768e",
        "brightGreen": "#9ece6a",
        "brightYellow": "#e0af68",
        "brightBlue": "#7aa2f7",
        "brightPurple": "#bb9af7",
        "brightCyan": "#7dcfff",
        "brightWhite": "#c0caf5",
    }
    result = modifier.upsert_windows_terminal_scheme(updated_scheme)
    parsed = parse_jsonc(result)
    assert len(parsed["schemes"]) == 1
    assert parsed["schemes"][0]["background"] == "#1a1b26"


def test_surgical_set_profiles_defaults() -> None:
    original = """{
        "profiles": {
            "defaults": {
                // Keep this comment
                "font": { "face": "Consolas" }
            }
        }
    }"""
    modifier = JsoncModifier(original)
    result = modifier.set_profile_color_scheme("Nord", apply_to_defaults=True)
    assert "// Keep this comment" in result
    parsed = parse_jsonc(result)
    assert parsed["profiles"]["defaults"]["colorScheme"] == "Nord"
    assert parsed["profiles"]["defaults"]["font"]["face"] == "Consolas"
