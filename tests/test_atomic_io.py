"""Tests for atomic I/O, backup rotation, and sharing-violation retry loop."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from unittest.mock import patch
import pytest

from omarchy_theme.atomic_io import (
    AtomicWriteError,
    atomic_write_text,
    create_safety_backup,
    restore_from_backup,
    rotate_backups,
    safe_read_text,
)


def test_atomic_write_creates_file_and_cleans_staging() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        target = Path(tmp_dir) / "test.json"
        content = '{"hello": "world"}'

        result = atomic_write_text(target, content)
        assert result.resolve() == target.resolve()
        assert target.exists()
        assert target.read_text(encoding="utf-8") == content

        # Verify no staging files left in the directory
        staging_files = list(Path(tmp_dir).glob("*.omarchy_tmp.*"))
        assert len(staging_files) == 0


def test_backup_rotation() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        target = Path(tmp_dir) / "settings.json"
        target.write_text("v1", encoding="utf-8")

        # 1st update
        atomic_write_text(target, "v2", make_backup=True)
        bak = target.with_name("settings.json.bak")
        assert bak.exists()
        assert bak.read_text(encoding="utf-8") == "v1"
        assert target.read_text(encoding="utf-8") == "v2"

        # 2nd update
        atomic_write_text(target, "v3", make_backup=True)
        bak1 = target.with_name("settings.json.bak.1")
        assert bak.read_text(encoding="utf-8") == "v2"
        assert bak1.read_text(encoding="utf-8") == "v1"

        # Restore from backup
        restored = restore_from_backup(target)
        assert restored is not None
        assert restored.resolve() == bak.resolve()
        assert target.read_text(encoding="utf-8") == "v2"


def test_sharing_violation_retry_success() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        target = Path(tmp_dir) / "locked.json"
        target.write_text("initial", encoding="utf-8")

        real_replace = os.replace
        calls = 0

        def flaky_replace(src: Path | str, dst: Path | str) -> None:
            nonlocal calls
            calls += 1
            if calls < 3:
                # Simulate Windows ERROR_SHARING_VIOLATION / PermissionError
                raise PermissionError("The process cannot access the file because it is being used by another process.")
            real_replace(src, dst)

        with patch("os.replace", side_effect=flaky_replace):
            atomic_write_text(target, "updated", initial_retry_delay=0.01)

        assert calls == 3
        assert target.read_text(encoding="utf-8") == "updated"


def test_permanent_lock_raises_atomic_error_and_preserves_target() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        target = Path(tmp_dir) / "permanent_lock.json"
        target.write_text("original_content", encoding="utf-8")

        def always_fail(src: Path | str, dst: Path | str) -> None:
            raise PermissionError("Access is denied")

        with patch("os.replace", side_effect=always_fail):
            with pytest.raises(AtomicWriteError):
                atomic_write_text(target, "new_content", max_retries=3, initial_retry_delay=0.01)

        # Original must be untouched!
        assert target.read_text(encoding="utf-8") == "original_content"
        # Staging file cleaned up
        staging_files = list(Path(tmp_dir).glob("*.omarchy_tmp.*"))
        assert len(staging_files) == 0


def test_safe_read_encodings() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        p_utf8 = Path(tmp_dir) / "utf8.txt"
        p_utf8.write_bytes(b"hello world")
        text, enc = safe_read_text(p_utf8)
        assert text == "hello world"
        assert enc == "utf-8"

        p_bom = Path(tmp_dir) / "bom.txt"
        p_bom.write_bytes(b"\xef\xbb\xbfhello with bom")
        text, enc = safe_read_text(p_bom)
        assert text == "hello with bom"
        assert enc == "utf-8-sig"

        p_u16 = Path(tmp_dir) / "u16.txt"
        p_u16.write_bytes(b"\xff\xfe" + "hello utf16".encode("utf-16le"))
        text, enc = safe_read_text(p_u16)
        assert text == "hello utf16"
        assert enc == "utf-16le"
