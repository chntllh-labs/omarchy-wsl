"""Lock-protected atomic file updates for theme targets on ext4 and WSL DrvFs.

Every change to a target file is one transaction under an exclusive lock file:
read -> transform -> (skip if unchanged) -> stage -> fsync -> rotate backups ->
atomic rename. ``flock(2)`` is not used: it is unreliable on DrvFs (9p), so
the lock is an ``O_CREAT | O_EXCL`` file next to the target, with stale-lock
recovery (dead holder PID in the same PID namespace, or lock age).
"""

from __future__ import annotations

import os
import random
import shutil
import socket
import stat
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple

LOCK_SUFFIX = ".omarchy-lock"
ORIG_SUFFIX = ".omarchy-orig"
STAGING_MARKER = ".omarchy_tmp."


class AtomicWriteError(IOError):
    """Raised when an atomic write fails; the target is left untouched."""


class LockTimeout(AtomicWriteError):
    """Raised when the target's lock file could not be acquired in time."""


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
def safe_read_text(path: Path | str) -> Tuple[str, str]:
    """Read file content with auto-detection of UTF-8, UTF-8-BOM, and UTF-16.

    Returns (text_content, detected_encoding).
    """
    file_path = Path(path)
    if not file_path.exists():
        raise FileNotFoundError(f"File not found: {file_path}")

    raw_bytes = file_path.read_bytes()

    if raw_bytes.startswith(b"\xef\xbb\xbf"):
        return raw_bytes[3:].decode("utf-8"), "utf-8-sig"
    if raw_bytes.startswith(b"\xff\xfe"):
        return raw_bytes[2:].decode("utf-16le"), "utf-16le"
    if raw_bytes.startswith(b"\xfe\xff"):
        return raw_bytes[2:].decode("utf-16be"), "utf-16be"
    try:
        return raw_bytes.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return raw_bytes.decode("latin-1"), "latin-1"


# ---------------------------------------------------------------------------
# Lock file
# ---------------------------------------------------------------------------
def _pid_namespace() -> str:
    try:
        return os.readlink("/proc/self/ns/pid")
    except OSError:
        return ""


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def _parse_lock(text: str) -> Dict[str, str]:
    info: Dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            info[key.strip()] = value.strip()
    return info


class FileLock:
    """Exclusive ``O_EXCL`` lock file guarding one target path.

    A lock is considered stale when its holder PID is dead (same host and PID
    namespace only: WSL distros share a kernel but not PID namespaces) or when
    it is older than ``stale_after`` seconds. Breaking a stale lock renames it
    away and verifies the content first, so a lock created in the meantime by
    another process is never deleted.
    """

    def __init__(
        self,
        target: Path | str,
        timeout: float = 30.0,
        stale_after: float = 60.0,
        poll_interval: float = 0.02,
    ) -> None:
        target = Path(target)
        self.path = target.with_name(f"{target.name}{LOCK_SUFFIX}")
        self.timeout = timeout
        self.stale_after = stale_after
        self.poll_interval = poll_interval
        self.token = uuid.uuid4().hex
        self._content = (
            f"pid={os.getpid()}\nhost={socket.gethostname()}\n"
            f"pidns={_pid_namespace()}\ntoken={self.token}\ntime={time.time():.3f}\n"
        )
        self.held = False

    # -- acquisition ---------------------------------------------------------
    def acquire(self) -> "FileLock":
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            except FileExistsError:
                if self._break_if_stale():
                    continue
                if time.monotonic() >= deadline:
                    raise LockTimeout(f"Timed out waiting for {self.path} (another theme sync is running)")
                time.sleep(self.poll_interval * (1.0 + random.random()))
                continue
            except OSError as e:
                raise AtomicWriteError(f"Cannot create lock file {self.path}: {e}") from e
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(self._content)
            self.held = True
            return self

    def _is_stale(self, content: str, mtime: float) -> bool:
        if time.time() - mtime > self.stale_after:
            return True
        info = _parse_lock(content)
        pid = info.get("pid", "")
        if (
            pid.isdigit()
            and info.get("host") == socket.gethostname()
            and info.get("pidns")
            and info.get("pidns") == _pid_namespace()
        ):
            return not _pid_alive(int(pid))
        return False

    def _break_if_stale(self) -> bool:
        """Remove a stale lock. True when the caller should retry at once."""
        try:
            mtime = self.path.stat().st_mtime
            content = self.path.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return True
        except OSError:
            return False
        if not self._is_stale(content, mtime):
            return False
        moved = self.path.with_name(f"{self.path.name}.stale.{os.getpid()}.{uuid.uuid4().hex[:8]}")
        try:
            os.rename(self.path, moved)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        try:
            moved_content = moved.read_text(encoding="utf-8", errors="replace")
        except OSError:
            moved_content = None
        if moved_content != content:
            # A fresh lock replaced the stale one between our read and rename:
            # hand it back (link() fails instead of overwriting a newer lock).
            try:
                os.link(moved, self.path)
            except OSError:
                pass
        try:
            moved.unlink()
        except OSError:
            pass
        return moved_content == content

    # -- ownership -----------------------------------------------------------
    def verify(self) -> None:
        """Raise AtomicWriteError unless this process still owns the lock."""
        try:
            info = _parse_lock(self.path.read_text(encoding="utf-8", errors="replace"))
        except OSError as e:
            raise AtomicWriteError(f"Lost lock {self.path}: {e}") from e
        if info.get("token") != self.token:
            raise AtomicWriteError(f"Lost lock {self.path} to another process; not committing.")

    def release(self) -> None:
        if not self.held:
            return
        self.held = False
        try:
            info = _parse_lock(self.path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return
        if info.get("token") == self.token:
            try:
                self.path.unlink()
            except OSError:
                pass

    def __enter__(self) -> "FileLock":
        return self.acquire()

    def __exit__(self, *exc: object) -> None:
        self.release()


# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
def _silent_rename(src: Path, dst: Path) -> None:
    # rename(2) replaces dst atomically on POSIX; a vanished src is fine.
    try:
        os.rename(src, dst)
    except FileNotFoundError:
        pass


def rotate_backups(target_path: Path, max_backups: int = 3) -> None:
    """Shift backups: .bak -> .bak.1 -> ... keeping ``max_backups`` files.

    Tolerates files vanishing underneath (ENOENT) at every step.
    """
    target_path = Path(target_path)
    name = target_path.name
    if max_backups <= 1:
        return
    oldest = target_path.with_name(f"{name}.bak.{max_backups - 1}")
    try:
        oldest.unlink()
    except FileNotFoundError:
        pass
    for i in range(max_backups - 2, 0, -1):
        _silent_rename(target_path.with_name(f"{name}.bak.{i}"), target_path.with_name(f"{name}.bak.{i + 1}"))
    _silent_rename(target_path.with_name(f"{name}.bak"), target_path.with_name(f"{name}.bak.1"))


def create_safety_backup(target_path: Path, max_backups: int = 3) -> Optional[Path]:
    """Rotate backups and copy the current file to ``<name>.bak``.

    The very first backup is also kept as ``<name>.omarchy-orig`` and never
    rotated, so the pre-Omarchy original survives any number of syncs.
    """
    target_path = Path(target_path)
    if not target_path.exists():
        return None
    orig = target_path.with_name(f"{target_path.name}{ORIG_SUFFIX}")
    if not orig.exists():
        try:
            shutil.copy2(target_path, orig)
        except FileNotFoundError:
            return None
    rotate_backups(target_path, max_backups=max_backups)
    bak_path = target_path.with_name(f"{target_path.name}.bak")
    try:
        shutil.copy2(target_path, bak_path)
    except FileNotFoundError:
        return None
    return bak_path


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------
def _encode(content: str, encoding: str) -> bytes:
    if encoding == "utf-8-sig":
        return b"\xef\xbb\xbf" + content.encode("utf-8")
    return content.encode(encoding)


def _write_locked(
    path: Path,
    content: str,
    encoding: str,
    make_backup: bool,
    max_backups: int,
    max_retries: int,
    initial_retry_delay: float,
    lock: Optional[FileLock],
) -> bool:
    """Commit ``content`` to ``path`` (caller holds the lock). False = no-op."""
    data = _encode(content, encoding)
    mode: Optional[int] = None
    if path.exists():
        try:
            if path.read_bytes() == data:
                return False  # unchanged: no write, no backup rotation
            mode = stat.S_IMODE(path.stat().st_mode)
        except FileNotFoundError:
            mode = None

    nonce = f"{os.getpid()}.{time.time_ns()}.{uuid.uuid4().hex[:6]}"
    temp_path = path.parent / f"{path.name}{STAGING_MARKER}{nonce}"
    try:
        with open(temp_path, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            try:
                os.chmod(temp_path, mode)
            except OSError:
                pass  # DrvFs without metadata cannot store modes
        if not temp_path.exists() or (temp_path.stat().st_size == 0 and len(data) > 0):
            raise AtomicWriteError(f"Staging file verification failed: {temp_path}")

        if make_backup and path.exists():
            create_safety_backup(path, max_backups=max_backups)
        if lock is not None:
            lock.verify()

        last_err: Optional[Exception] = None
        delay = initial_retry_delay
        for _ in range(max_retries):
            try:
                os.replace(temp_path, path)
                last_err = None
                break
            except (PermissionError, OSError) as e:
                # Transient sharing violation (WT watcher, editor, antivirus).
                last_err = e
                time.sleep(delay)
                delay *= 2
        if last_err is not None:
            raise AtomicWriteError(
                f"Failed to atomically swap {temp_path} -> {path} after {max_retries} attempts: {last_err}"
            )
        return True
    finally:
        if temp_path.exists():
            try:
                temp_path.unlink()
            except OSError:
                pass


def atomic_write_text(
    target_path: Path | str,
    content: str,
    encoding: str = "utf-8",
    make_backup: bool = True,
    max_backups: int = 3,
    max_retries: int = 5,
    initial_retry_delay: float = 0.05,
    lock_timeout: float = 30.0,
) -> Path:
    """Atomically write ``content`` to ``target_path`` under the target's lock.

    Unchanged content is not rewritten and does not rotate backups. The file
    mode of an existing target is preserved.
    """
    path = Path(target_path).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    with FileLock(path, timeout=lock_timeout) as lock:
        _write_locked(path, content, encoding, make_backup, max_backups, max_retries, initial_retry_delay, lock)
    return path


@dataclass
class UpdateResult:
    """Outcome of :func:`atomic_update_text`."""

    path: Path
    changed: bool
    old_text: Optional[str]
    new_text: Optional[str]


def atomic_update_text(
    target_path: Path | str,
    transform: Callable[[Optional[str]], Optional[str]],
    encoding: str = "utf-8",
    make_backup: bool = True,
    max_backups: int = 3,
    max_retries: int = 5,
    initial_retry_delay: float = 0.05,
    lock_timeout: float = 30.0,
    create_parent: bool = True,
) -> UpdateResult:
    """Read-modify-write ``target_path`` as one locked transaction.

    ``transform`` receives the current text (``None`` if the file does not
    exist) and returns the new text, or ``None`` to leave the file alone. An
    exception raised by ``transform`` aborts the transaction untouched.
    """
    path = Path(target_path).resolve()
    if create_parent:
        path.parent.mkdir(parents=True, exist_ok=True)
    with FileLock(path, timeout=lock_timeout) as lock:
        old_text = safe_read_text(path)[0] if path.exists() else None
        new_text = transform(old_text)
        if new_text is None:
            return UpdateResult(path, False, old_text, old_text)
        changed = _write_locked(
            path, new_text, encoding, make_backup, max_backups, max_retries, initial_retry_delay, lock
        )
        return UpdateResult(path, changed, old_text, new_text)


def restore_from_backup(target_path: Path | str) -> Optional[Path]:
    """Restore ``target_path`` from its most recent ``.bak`` (atomically, locked)."""
    path = Path(target_path).resolve()
    bak_path = path.with_name(f"{path.name}.bak")
    if not bak_path.exists():
        return None
    data = bak_path.read_bytes()
    with FileLock(path) as lock:
        nonce = f"{os.getpid()}.{time.time_ns()}.{uuid.uuid4().hex[:6]}"
        temp_path = path.parent / f"{path.name}{STAGING_MARKER}{nonce}"
        try:
            with open(temp_path, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            if path.exists():
                try:
                    os.chmod(temp_path, stat.S_IMODE(path.stat().st_mode))
                except OSError:
                    pass
            lock.verify()
            os.replace(temp_path, path)
        finally:
            if temp_path.exists():
                try:
                    temp_path.unlink()
                except OSError:
                    pass
    return bak_path
