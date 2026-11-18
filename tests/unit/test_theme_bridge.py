"""Unit tests for tools/omarchy-theme-bridge.py.

Run from the repository root:  python3 -m unittest discover -s tests/unit -v

Set OMARCHY_SRC to an upstream Omarchy checkout to also check palette parity
against upstream's own resolver (bin/omarchy-theme-color) for every theme.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "tests" / "fixtures"

spec = importlib.util.spec_from_file_location("bridge", REPO / "tools" / "omarchy-theme-bridge.py")
bridge = importlib.util.module_from_spec(spec)
sys.modules["bridge"] = bridge
spec.loader.exec_module(bridge)


def tokyo_night() -> "bridge.Theme":
    return bridge.Theme("Tokyo Night", bridge.resolve_palette(bridge.TOKYO_NIGHT), dict(bridge.TOKYO_NIGHT_VSCODE))


class PaletteTests(unittest.TestCase):
    def test_parse_colors_toml_matches_upstream_rules(self):
        parsed = bridge.parse_colors_toml(
            '# comment\nbackground = "#1a1b26" # inline\nforeground=#a9b1d6\n'
            'bad key = "#000000"\nevil = "$(rm -rf /)"\n[section]\n'
        )
        self.assertEqual(parsed["background"], "#1a1b26")
        self.assertEqual(parsed["foreground"], "#a9b1d6")
        self.assertEqual(parsed["badkey"], "#000000")  # upstream strips spaces from keys
        self.assertNotIn("evil", parsed)

    def test_tokyo_night_ansi_mapping(self):
        scheme = bridge.terminal_scheme(tokyo_night())
        self.assertEqual(scheme["name"], "Omarchy Tokyo Night")
        self.assertEqual(scheme["black"], "#1a1b26")  # color0 = background
        self.assertEqual(scheme["white"], "#a9b1d6")  # color7 = foreground
        self.assertEqual(scheme["brightBlack"], "#414868")  # color8 = muted
        self.assertEqual(scheme["brightWhite"], "#c0caf5")  # color15 = bright_foreground
        self.assertEqual(scheme["purple"], "#ad8ee6")
        self.assertEqual(scheme["cursorColor"], "#c0caf5")
        self.assertEqual(scheme["selectionBackground"], "#292e42")
        for key in bridge.WT_ANSI_KEYS + ["background", "foreground"]:
            self.assertRegex(scheme[key], r"^#[0-9a-f]{6}$", key)

    def test_derived_shades_for_sparse_theme(self):
        palette = bridge.resolve_palette({"background": "#000000", "foreground": "#ffffff", "red": "#ff0000"})
        self.assertEqual(palette["bright_red"], "#ff3333")
        self.assertEqual(palette["color9"], "#ff3333")
        self.assertEqual(palette["dark_background"], "#000000")
        self.assertEqual(palette["mode"], "dark")

    def test_legacy_ansi_only_theme(self):
        raw = {f"color{i}": f"#{i:02x}{i:02x}{i:02x}" for i in range(16)}
        palette = bridge.resolve_palette(raw)
        self.assertEqual(palette["background"], "#000000")
        self.assertEqual(palette["red"], "#010101")
        self.assertEqual(palette["color15"], "#0f0f0f")

    @unittest.skipUnless(os.environ.get("OMARCHY_SRC"), "OMARCHY_SRC not set")
    def test_parity_with_upstream_resolver(self):
        src = Path(os.environ["OMARCHY_SRC"])
        resolver = src / "bin" / "omarchy-theme-color"
        themes = sorted((src / "themes").glob("*/colors.toml"))
        self.assertTrue(themes)
        for colors in themes:
            out = subprocess.run(["bash", str(resolver), "--file", str(colors), "--all"],
                                 capture_output=True, text=True, check=True).stdout
            upstream = dict(line.split("\t", 1) for line in out.splitlines() if "\t" in line)
            ours = bridge.resolve_palette(bridge.parse_colors_toml(colors.read_text()))
            for key in [f"color{i}" for i in range(16)] + ["cursor", "selection_background", "background", "foreground"]:
                self.assertEqual(ours.get(key), upstream.get(key), f"{colors.parent.name}: {key}")


class JsoncTests(unittest.TestCase):
    def test_parser_handles_comments_trailing_commas_and_bom(self):
        text = (FIXTURES / "windows-terminal-settings.json").read_text(encoding="utf-8")
        doc = bridge.JsoncDocument(text)
        self.assertTrue(doc.bom)
        names = [n.to_python()["name"] for n in bridge.profile_nodes(doc.root)]
        self.assertEqual(names, ["Windows PowerShell", "Ubuntu-24.04", "Omarchy"])

    def test_rejects_garbage(self):
        for bad in ['{"a": }', '{"a": 1', "[1, 2", '{"a" 1}', "/* open"]:
            with self.assertRaises(bridge.BridgeError, msg=bad):
                bridge.parse_jsonc(bad)

    def test_string_with_comment_markers_is_not_a_comment(self):
        node = bridge.parse_jsonc('{"url": "https://x//y/*z*/", "n": 1}')
        self.assertEqual(node.to_python(), {"url": "https://x//y/*z*/", "n": 1})


class TerminalPatchTests(unittest.TestCase):
    def setUp(self):
        self.original = (FIXTURES / "windows-terminal-settings.json").read_text(encoding="utf-8")

    def test_adds_scheme_and_switches_profile_preserving_comments(self):
        updated, notes = bridge.patch_terminal_settings(self.original, tokyo_night(), "Omarchy")
        self.assertEqual(notes, [])
        self.assertTrue(updated.startswith("﻿"))
        self.assertIn("// This file was initially generated by Windows Terminal", updated)
        self.assertIn("// Make changes here to the powershell.exe profile.", updated)
        data = bridge.parse_jsonc(updated[1:]).to_python()
        schemes = {s["name"]: s for s in data["schemes"]}
        self.assertIn("Campbell", schemes)
        self.assertEqual(schemes["Omarchy Tokyo Night"]["background"], "#1a1b26")
        profiles = {p["name"]: p for p in data["profiles"]["list"]}
        self.assertEqual(profiles["Omarchy"]["colorScheme"], "Omarchy Tokyo Night")
        self.assertNotIn("colorScheme", profiles["Ubuntu-24.04"])
        self.assertEqual(profiles["Omarchy"]["font"], {"size": 11})

    def test_idempotent(self):
        once, _ = bridge.patch_terminal_settings(self.original, tokyo_night(), "Omarchy")
        twice, _ = bridge.patch_terminal_settings(once, tokyo_night(), "Omarchy")
        self.assertEqual(once, twice)

    def test_switching_theme_replaces_profile_scheme(self):
        once, _ = bridge.patch_terminal_settings(self.original, tokyo_night(), "Omarchy")
        light = bridge.Theme("Light Test", bridge.resolve_palette({"background": "#ffffff", "foreground": "#000000"}))
        twice, _ = bridge.patch_terminal_settings(once, light, "omarchy")  # case-insensitive match
        data = bridge.parse_jsonc(twice[1:]).to_python()
        profile = next(p for p in data["profiles"]["list"] if p["name"] == "Omarchy")
        self.assertEqual(profile["colorScheme"], "Omarchy Light Test")
        self.assertEqual({s["name"] for s in data["schemes"]}, {"Campbell", "Omarchy Tokyo Night", "Omarchy Light Test"})

    def test_updates_stale_scheme_in_place(self):
        once, _ = bridge.patch_terminal_settings(self.original, tokyo_night(), "Omarchy")
        stale = once.replace('"background": "#1a1b26"', '"background": "#123456"', 1)
        fixed, _ = bridge.patch_terminal_settings(stale, tokyo_night(), "Omarchy")
        data = bridge.parse_jsonc(fixed[1:]).to_python()
        tn = [s for s in data["schemes"] if s["name"] == "Omarchy Tokyo Night"]
        self.assertEqual(len(tn), 1)
        self.assertEqual(tn[0]["background"], "#1a1b26")

    def test_font_override(self):
        updated, _ = bridge.patch_terminal_settings(self.original, tokyo_night(), "Omarchy", "JetBrainsMono Nerd Font")
        data = bridge.parse_jsonc(updated[1:]).to_python()
        profile = next(p for p in data["profiles"]["list"] if p["name"] == "Omarchy")
        self.assertEqual(profile["font"], {"size": 11, "face": "JetBrainsMono Nerd Font"})

    def test_missing_profile_is_reported(self):
        updated, notes = bridge.patch_terminal_settings(self.original, tokyo_night(), "Nope")
        self.assertEqual(len(notes), 1)
        self.assertIn("Omarchy Tokyo Night", updated)

    def test_minimal_documents(self):
        for text in ["{}", '{"profiles": []}', '{"schemes": [], "profiles": {"list": []}}', "{\r\n}\r\n"]:
            updated, _ = bridge.patch_terminal_settings(text, tokyo_night(), "Omarchy")
            data = bridge.parse_jsonc(updated).to_python()
            self.assertEqual(data["schemes"][0]["name"], "Omarchy Tokyo Night", text)

    def test_crlf_preserved(self):
        crlf = self.original.replace("\n", "\r\n")
        updated, _ = bridge.patch_terminal_settings(crlf, tokyo_night(), "Omarchy")
        self.assertNotIn("\n", updated.replace("\r\n", ""))

    def test_legacy_profiles_array(self):
        text = '{"profiles": [{"name": "Omarchy"}], "schemes": []}'
        updated, _ = bridge.patch_terminal_settings(text, tokyo_night(), "Omarchy")
        self.assertEqual(bridge.parse_jsonc(updated).to_python()["profiles"][0]["colorScheme"], "Omarchy Tokyo Night")


class VSCodePatchTests(unittest.TestCase):
    def test_replaces_value_and_keeps_comments(self):
        original = (FIXTURES / "vscode-settings.json").read_text()
        updated = bridge.patch_vscode_settings(original, "Tokyo Night")
        self.assertIn('"workbench.colorTheme": "Tokyo Night", // set by hand', updated)
        self.assertIn("// Keep the editor calm.", updated)
        self.assertEqual(bridge.patch_vscode_settings(updated, "Tokyo Night"), updated)

    def test_inserts_into_empty_or_missing(self):
        for text in ["", "{}", "{\n}\n", '{\n    "a": 1\n}\n']:
            updated = bridge.patch_vscode_settings(text, "Tokyo Night")
            self.assertEqual(bridge.parse_jsonc(updated).to_python()["workbench.colorTheme"], "Tokyo Night", repr(text))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.home = self.tmp / "Users" / "alice"
        wt = self.home / "AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState"
        wt.mkdir(parents=True)
        shutil.copy(FIXTURES / "windows-terminal-settings.json", wt / "settings.json")
        self.wt_settings = wt / "settings.json"
        code = self.home / "AppData/Roaming/Code/User"
        code.mkdir(parents=True)
        shutil.copy(FIXTURES / "vscode-settings.json", code / "settings.json")
        self.code_settings = code / "settings.json"
        self.ext_dir = self.home / ".vscode/extensions"
        self.ext_dir.mkdir(parents=True)
        os.environ.pop("OMARCHY_WT_SETTINGS", None)

    def run_cli(self, *args):
        return bridge.main(["Tokyo Night", "--windows-home", str(self.home), "--profile", "Omarchy", *args])

    def test_sync_writes_both_targets_with_backup(self):
        (self.ext_dir / "enkia.tokyo-night-1.1.2").mkdir()
        self.assertEqual(self.run_cli("--quiet"), 0)
        wt = bridge.parse_jsonc(self.wt_settings.read_text(encoding="utf-8")[1:]).to_python()
        self.assertIn("Omarchy Tokyo Night", {s["name"] for s in wt["schemes"]})
        self.assertTrue((self.wt_settings.parent / "settings.json.omarchy-backup").exists())
        code = bridge.parse_jsonc(self.code_settings.read_text()).to_python()
        self.assertEqual(code["workbench.colorTheme"], "Tokyo Night")

    def test_vscode_skipped_without_extension(self):
        before = self.code_settings.read_text()
        self.assertEqual(self.run_cli("--quiet"), 0)
        self.assertEqual(self.code_settings.read_text(), before)

    def test_check_and_dry_run_do_not_write(self):
        before = self.wt_settings.read_bytes()
        self.assertEqual(self.run_cli("--check", "--quiet"), 0)
        self.assertEqual(self.run_cli("--dry-run", "--quiet"), 0)
        self.assertEqual(self.wt_settings.read_bytes(), before)

    def test_invalid_settings_fail_without_touching_file(self):
        self.wt_settings.write_text("{ not json")
        self.assertEqual(self.run_cli("--quiet", "--no-vscode"), 1)
        self.assertEqual(self.wt_settings.read_text(), "{ not json")

    def test_unknown_theme(self):
        self.assertEqual(bridge.main(["No Such Theme", "--windows-home", str(self.home)]), 2)

    def test_theme_directory_argument(self):
        theme_dir = self.tmp / "my-theme"
        theme_dir.mkdir()
        (theme_dir / "colors.toml").write_text('background = "#101010"\nforeground = "#efefef"\n')
        rc = bridge.main([str(theme_dir), "--settings", str(self.wt_settings), "--profile", "Omarchy",
                          "--no-vscode", "--quiet"])
        self.assertEqual(rc, 0)
        self.assertIn("Omarchy My Theme", self.wt_settings.read_text(encoding="utf-8"))

    def test_emit_terminal_profile(self):
        template = bridge.terminal_profile_template(tokyo_night(), "JetBrainsMono Nerd Font")
        self.assertEqual(template["profiles"][0]["colorScheme"], "Omarchy Tokyo Night")
        self.assertEqual(template["profiles"][0]["font"]["face"], "JetBrainsMono Nerd Font")
        self.assertEqual(template["schemes"][0]["name"], "Omarchy Tokyo Night")
        json.dumps(template)


if __name__ == "__main__":
    unittest.main()
