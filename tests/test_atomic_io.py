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


# ---------------------------------------------------------------------------
# Locking, no-op skipping, mode preservation, rotation (#22, #51)
# ---------------------------------------------------------------------------
import json
import socket
import stat
import subprocess
import sys
import time

from omarchy_theme.atomic_io import (
    LOCK_SUFFIX,
    ORIG_SUFFIX,
    FileLock,
    LockTimeout,
    atomic_update_text,
)

REPO = Path(__file__).resolve().parent.parent


def _leftovers(directory: Path) -> list:
    return [p.name for p in directory.iterdir() if ".omarchy_tmp." in p.name or LOCK_SUFFIX in p.name]


def test_noop_write_skips_rewrite_and_rotation(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    target.write_text("v1", encoding="utf-8")
    atomic_write_text(target, "v2")
    bak = target.with_name("settings.json.bak")
    assert bak.read_text(encoding="utf-8") == "v1"
    before = target.stat().st_mtime_ns
    time.sleep(0.02)
    atomic_write_text(target, "v2")  # unchanged content
    assert target.stat().st_mtime_ns == before
    assert bak.read_text(encoding="utf-8") == "v1"
    assert not target.with_name("settings.json.bak.1").exists()


def test_file_mode_is_preserved(tmp_path: Path) -> None:
    target = tmp_path / "secret.json"
    target.write_text("old", encoding="utf-8")
    os.chmod(target, 0o600)
    atomic_write_text(target, "new")
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert target.read_text(encoding="utf-8") == "new"


def test_rotation_keeps_max_backups_and_original(tmp_path: Path) -> None:
    target = tmp_path / "s.json"
    target.write_text("v0", encoding="utf-8")
    for i in range(1, 7):
        atomic_write_text(target, f"v{i}", max_backups=3)
    assert target.with_name("s.json.bak").read_text(encoding="utf-8") == "v5"
    assert target.with_name("s.json.bak.1").read_text(encoding="utf-8") == "v4"
    assert target.with_name("s.json.bak.2").read_text(encoding="utf-8") == "v3"
    assert not target.with_name("s.json.bak.3").exists()
    # The pre-Omarchy original survives every rotation.
    assert target.with_name(f"s.json{ORIG_SUFFIX}").read_text(encoding="utf-8") == "v0"


def test_rotation_tolerates_missing_backups(tmp_path: Path) -> None:
    target = tmp_path / "t.json"
    target.write_text("x", encoding="utf-8")
    target.with_name("t.json.bak.2").write_text("orphan", encoding="utf-8")
    rotate_backups(target, max_backups=4)  # .bak and .bak.1 absent: no ENOENT
    rotate_backups(tmp_path / "missing.json", max_backups=3)
    assert target.with_name("t.json.bak.3").read_text(encoding="utf-8") == "orphan"


def test_lock_released_and_no_leftovers(tmp_path: Path) -> None:
    target = tmp_path / "w.json"
    atomic_write_text(target, "a")
    atomic_update_text(target, lambda cur: (cur or "") + "b")
    assert target.read_text(encoding="utf-8") == "ab"
    assert _leftovers(tmp_path) == []


def test_transform_error_aborts_without_writing(tmp_path: Path) -> None:
    target = tmp_path / "e.json"
    target.write_text("keep", encoding="utf-8")

    def boom(_cur):
        raise ValueError("bad edit")

    with pytest.raises(ValueError):
        atomic_update_text(target, boom)
    assert target.read_text(encoding="utf-8") == "keep"
    assert _leftovers(tmp_path) == []


def test_live_lock_blocks_until_timeout(tmp_path: Path) -> None:
    target = tmp_path / "busy.json"
    target.write_text("orig", encoding="utf-8")
    with FileLock(target):
        with pytest.raises(LockTimeout):
            atomic_write_text(target, "other", lock_timeout=0.3)
    assert target.read_text(encoding="utf-8") == "orig"


def test_stale_lock_by_age_is_recovered(tmp_path: Path) -> None:
    target = tmp_path / "aged.json"
    lock = tmp_path / f"aged.json{LOCK_SUFFIX}"
    lock.write_text("pid=1\nhost=elsewhere\npidns=\ntoken=x\n", encoding="utf-8")
    old = time.time() - 3600
    os.utime(lock, (old, old))
    atomic_write_text(target, "fresh", lock_timeout=2.0)
    assert target.read_text(encoding="utf-8") == "fresh"
    assert not lock.exists()


def test_stale_lock_of_dead_pid(tmp_path: Path) -> None:
    """A lock whose holder died is broken at once when the holder's PID
    namespace is known (Linux); elsewhere only the age rule applies."""
    target = tmp_path / "dead.json"
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    try:
        pidns = os.readlink("/proc/self/ns/pid")
    except OSError:
        pidns = ""
    lock = tmp_path / f"dead.json{LOCK_SUFFIX}"
    lock.write_text(
        f"pid={proc.pid}\nhost={socket.gethostname()}\npidns={pidns}\ntoken=dead\n", encoding="utf-8"
    )
    if pidns:
        start = time.monotonic()
        atomic_write_text(target, "recovered", lock_timeout=5.0)
        assert time.monotonic() - start < 2.0
        assert target.read_text(encoding="utf-8") == "recovered"
    else:
        with pytest.raises(LockTimeout):
            atomic_write_text(target, "recovered", lock_timeout=0.3)


def test_lock_verify_detects_a_stolen_lock(tmp_path: Path) -> None:
    target = tmp_path / "s.json"
    lock = FileLock(target).acquire()
    lock.path.write_text("pid=1\ntoken=someone-else\n", encoding="utf-8")
    with pytest.raises(AtomicWriteError):
        lock.verify()
    lock.release()
    assert lock.path.exists()  # release never deletes another holder's lock


_WORKER = r"""
import sys
from pathlib import Path
from omarchy_theme.adapters.windows_terminal import sync_windows_terminal
from omarchy_theme.palettes import NORD
from dataclasses import replace
target, wid, rounds = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
ok = 0
for j in range(rounds):
    res = sync_windows_terminal(target, replace(NORD, name=f"P{wid:02d}-{j:02d}"), target_profile="Omarchy")
    if res.success:
        ok += 1
    else:
        print(res.message, file=sys.stderr)
print(ok)
"""


def test_concurrent_syncs_lose_no_updates(tmp_path: Path) -> None:
    """12 processes x 15 syncs on one settings.json: all succeed, all 180
    schemes survive (no lost update), backups stay bounded, nothing leaks."""
    target = tmp_path / "settings.json"
    target.write_text('{\n  "profiles": { "list": [{ "name": "Omarchy" }] },\n  "schemes": []\n}\n', encoding="utf-8")
    env = dict(os.environ, PYTHONPATH=str(REPO / "lib"))
    procs = [
        subprocess.Popen(
            [sys.executable, "-c", _WORKER, str(target), str(i), "15"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
        )
        for i in range(12)
    ]
    results = [p.communicate(timeout=600) for p in procs]
    for proc, (out, err) in zip(procs, results):
        assert proc.returncode == 0, err
        assert out.strip() == "15", err
    from omarchy_theme.jsonc import parse_jsonc

    names = {s["name"] for s in parse_jsonc(target.read_text(encoding="utf-8"))["schemes"]}
    expected = {f"P{i:02d}-{j:02d}" for i in range(12) for j in range(15)}
    assert expected <= names
    assert _leftovers(tmp_path) == []
    backups = sorted(p.name for p in tmp_path.iterdir() if ".bak" in p.name)
    assert backups == ["settings.json.bak", "settings.json.bak.1", "settings.json.bak.2"]
    json.dumps(sorted(names))  # names are plain strings
