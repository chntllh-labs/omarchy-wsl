"""Tests for host environment detection, multi-variant WT discovery, and degradation."""

from __future__ import annotations

import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch
import pytest

from omarchy_theme.detector import HostDetector, TargetConfig


def test_windows_terminal_multi_variant_discovery() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        local_appdata = Path(tmp_dir) / "AppData" / "Local"
        packages_dir = local_appdata / "Packages"

        # 1. Stable
        stable_wt = packages_dir / "Microsoft.WindowsTerminal_8wekyb3d8bbwe" / "LocalState"
        stable_wt.mkdir(parents=True)
        (stable_wt / "settings.json").write_text("{}", encoding="utf-8")

        # 2. Preview
        preview_wt = packages_dir / "Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe" / "LocalState"
        preview_wt.mkdir(parents=True)
        (preview_wt / "settings.json").write_text("{}", encoding="utf-8")

        # 3. Unpackaged
        unpackaged_wt = local_appdata / "Microsoft" / "Windows Terminal"
        unpackaged_wt.mkdir(parents=True)
        (unpackaged_wt / "settings.json").write_text("{}", encoding="utf-8")

        detector = HostDetector(override_local_appdata=local_appdata)
        targets = detector.find_windows_terminal_targets()

        editions = {t.edition: t for t in targets}
        assert "stable" in editions
        assert "preview" in editions
        assert "unpackaged" in editions

        assert editions["stable"].exists is True
        assert editions["preview"].exists is True
        assert editions["unpackaged"].exists is True


def test_vscode_discovery() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        appdata = Path(tmp_dir) / "AppData" / "Roaming"

        stable_code = appdata / "Code" / "User"
        stable_code.mkdir(parents=True)
        (stable_code / "settings.json").write_text("{}", encoding="utf-8")

        detector = HostDetector(override_appdata=appdata)
        targets = detector.find_vscode_targets()

        editions = {t.edition: t for t in targets}
        assert "stable" in editions
        assert editions["stable"].exists is True


def test_interop_disabled_fallback_to_drvfs() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        # Simulate /mnt/c/Users/developer
        drvfs_root = Path(tmp_dir) / "mnt" / "c"
        user_dir = drvfs_root / "Users" / "developer"
        user_local = user_dir / "AppData" / "Local"
        user_local.mkdir(parents=True)
        (user_dir / "NTUSER.DAT").write_bytes(b"dummy")

        detector = HostDetector()
        detector._is_wsl = True
        detector._is_interop = False  # Interop disabled!

        # Mock mount roots to include our temporary fake /mnt/c
        with patch.object(detector, "_discover_windows_profile_from_drvfs", return_value=user_dir):
            local_appdata = detector.get_windows_local_appdata()
            assert local_appdata is not None
            assert local_appdata.resolve() == user_local.resolve()


def test_interop_disabled_and_no_drvfs_degrades_gracefully() -> None:
    detector = HostDetector()
    detector._is_wsl = True
    detector._is_interop = False

    with patch.object(detector, "_discover_windows_profile_from_drvfs", return_value=None):
        targets = detector.find_windows_terminal_targets()
        # Must return empty list without crashing
        assert targets == []
