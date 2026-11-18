"""rootfs.manifest gate: zero drift between the repository and the root filesystem.

`make install-rootfs DESTDIR=<tmp>` must install every tracked runtime file
(bin/, lib/, wsl/, tools/, assets/, packages/*.packages, docs) byte-for-byte
with the declared mode, nothing else, and every file the repository ships but
does not install must be excluded explicitly in rootfs.manifest.
"""

from __future__ import annotations

import fnmatch
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "scripts" / "install-manifest.sh"
MANIFEST = REPO / "rootfs.manifest"
RECORDS = ("usr/share/omarchy-wsl/manifest-pkg.sha256", "usr/share/omarchy-wsl/manifest-rootfs.sha256")
WSL_FILE_LIMIT = 1024 * 1024  # WslDistributionConfig.cpp: UtilReadFileRaw(path, 1 MiB)

# Tracked paths that are runtime candidates: each must be installed or excluded.
RUNTIME_PREFIXES = ("bin/", "lib/", "wsl/", "tools/", "assets/", "docs/")
RUNTIME_FILES = {"upstream.lock", "LICENSE", "README.md", "scripts/install-manifest.sh"}
RUNTIME_GLOBS = ("packages/*.packages",)
IGNORED_PARTS = {"__pycache__", ".DS_Store", ".pytest_cache"}

ENV = dict(
    os.environ,
    SOURCE_DATE_EPOCH="1700000000",
    OMARCHY_WSL_GIT_SHA="0123456789abcdef0123456789abcdef01234567",
    OMARCHY_WSL_PKGVER="4.5.0-1",
    LC_ALL="C",
)


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(INSTALLER), *args], cwd=REPO, env=ENV, capture_output=True, text=True, check=check)


def lock(key: str) -> str:
    for line in (REPO / "upstream.lock").read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1]
    raise KeyError(key)


def entries(scope: str = "rootfs") -> list[tuple[str, str, str, str, str]]:
    out = run("list", "--scope", scope).stdout
    return [tuple(line.split()) for line in out.splitlines() if line.strip()]  # type: ignore[misc]


def exclude_globs() -> list[str]:
    globs = []
    for line in MANIFEST.read_text().splitlines():
        line = line.split("#", 1)[0].split()
        if len(line) == 2 and line[0] == "exclude":
            globs.append(line[1])
    return globs


def tracked_files() -> list[str]:
    try:
        out = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True).stdout
        files = [f for f in out.splitlines() if (REPO / f).is_file()]
        # Untracked files still on disk (work in progress) count too: drift
        # must be caught before commit, not after.
        extra = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"], cwd=REPO,
                               capture_output=True, text=True, check=True).stdout
        return sorted(set(files) | {f for f in extra.splitlines() if (REPO / f).is_file()})
    except (subprocess.CalledProcessError, FileNotFoundError):
        found = []
        for root, dirs, names in os.walk(REPO):
            dirs[:] = [d for d in dirs if d not in {".git", "dist", *IGNORED_PARTS}]
            for name in names:
                found.append(str(Path(root, name).relative_to(REPO)))
        return sorted(found)


def is_runtime_candidate(path: str) -> bool:
    if any(part in IGNORED_PARTS for part in Path(path).parts) or path.endswith(".pyc"):
        return False
    return path.startswith(RUNTIME_PREFIXES) or path in RUNTIME_FILES or any(fnmatch.fnmatch(path, g) for g in RUNTIME_GLOBS)


@pytest.fixture(scope="module")
def rootfs():
    tmp = Path(tempfile.mkdtemp(prefix="omw-rootfs-"))
    try:
        result = subprocess.run(["make", "--no-print-directory", "install-rootfs", f"DESTDIR={tmp}"], cwd=REPO,
                                env=ENV, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr + result.stdout
        yield tmp
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_every_runtime_file_is_installed_or_excluded():
    sources = {e[3] for e in entries() if e[1] in ("file", "config")}
    excludes = exclude_globs()
    unclassified = [
        f for f in tracked_files()
        if is_runtime_candidate(f) and f not in sources and not any(fnmatch.fnmatch(f, g) for g in excludes)
    ]
    assert not unclassified, (
        "files neither installed by rootfs.manifest nor excluded there:\n  " + "\n  ".join(unclassified)
    )


def test_every_exclude_matches_something():
    files = tracked_files()
    stale = [g for g in exclude_globs() if not any(fnmatch.fnmatch(f, g) for f in files)]
    assert not stale, f"exclude globs that match nothing: {stale}"


def test_destinations_are_unique_and_absolute():
    seen: dict[str, str] = {}
    for scope, kind, mode, src, dest in entries():
        assert dest.startswith("/"), dest
        key = dest
        if key in seen and not (dest == "/etc/os-release" or seen[key] == src):
            pytest.fail(f"{dest} installed twice ({seen[key]} and {src})")
        seen[key] = src


def test_installed_tree_matches_manifest_exactly(rootfs: Path):
    expected: set[str] = set(RECORDS)
    for scope, kind, mode, src, dest in entries():
        rel = dest.lstrip("/")
        expected.add(rel)
        target = rootfs / rel
        if kind == "link":
            assert target.is_symlink(), f"{dest} is not a symlink"
            assert os.readlink(target) == src, f"{dest} -> {os.readlink(target)}, expected {src}"
            continue
        assert target.is_file() and not target.is_symlink(), f"{dest} missing"
        assert stat.S_IMODE(target.stat().st_mode) == int(mode, 8), f"{dest} mode {oct(target.stat().st_mode)} != {mode}"
        if kind in ("file", "config"):
            assert target.read_bytes() == (REPO / src).read_bytes(), f"{dest} differs from {src}"
            if mode in ("0755", "755") and not src.endswith((".py", ".ps1")):
                assert target.read_bytes()[:2] == b"#!", f"executable {dest} has no shebang"
    installed = set()
    for root, dirs, names in os.walk(rootfs):
        for name in names + [d for d in dirs if Path(root, d).is_symlink()]:
            installed.add(str(Path(root, name).relative_to(rootfs)))
    assert installed == expected, (
        f"unexpected: {sorted(installed - expected)}; missing: {sorted(expected - installed)}"
    )


def test_pkg_scope_is_rootfs_minus_machine_files():
    pkg = {e[4] for e in entries("pkg")}
    rootfs = {e[4] for e in entries("rootfs")}
    assert pkg < rootfs
    assert rootfs - pkg == {"/etc/os-release"}


def test_verify_detects_tampering_but_tolerates_config_edits(rootfs: Path):
    assert run("verify", "--root", str(rootfs)).returncode == 0
    wsl_conf = rootfs / "etc/wsl.conf"
    original = wsl_conf.read_bytes()
    wsl_conf.write_bytes(original + b"\n[user]\ndefault = alice\n")
    try:
        assert run("verify", "--root", str(rootfs)).returncode == 0, "config edits must not fail verify"
    finally:
        wsl_conf.write_bytes(original)
    tool = rootfs / "usr/bin/omarchy-doctor"
    saved = tool.read_bytes()
    tool.write_bytes(saved + b"\n# tampered\n")
    try:
        result = run("verify", "--root", str(rootfs), check=False)
        assert result.returncode != 0 and "CONTENT /usr/bin/omarchy-doctor" in result.stderr
    finally:
        tool.write_bytes(saved)
    os.chmod(tool, 0o644)
    try:
        result = run("verify", "--root", str(rootfs), check=False)
        assert result.returncode != 0 and "MODE /usr/bin/omarchy-doctor" in result.stderr
    finally:
        os.chmod(tool, 0o755)


def test_pkgbuild_backup_matches_config_entries():
    pkgbuild = (REPO / "packages/PKGBUILDs/omarchy-wsl/PKGBUILD").read_text()
    match = re.search(r"^backup=\((.*?)^\)", pkgbuild, re.S | re.M)
    assert match, "PKGBUILD has no multi-line backup=() array"
    backup = set(re.findall(r"'([^']+)'", match.group(1)))
    config = {e[4].lstrip("/") for e in entries("pkg") if e[1] == "config"}
    expected = "\n".join(f"  '{p}'" for p in sorted(config))
    assert backup == config, f"PKGBUILD backup=() must list exactly the manifest config entries:\nbackup=(\n{expected}\n)"


def test_wsl_distribution_files(rootfs: Path):
    conf = (rootfs / "etc/wsl-distribution.conf").read_text()
    for line in (
        "command = /usr/lib/wsl/oobe.sh",
        "defaultUid = 1000",
        "defaultName = Omarchy",
        "icon = /usr/lib/wsl/omarchy.ico",
        "ProfileTemplate = /usr/lib/wsl/terminal-profile.json",
    ):
        assert re.search(rf"^{re.escape(line)}$", conf, re.M), f"wsl-distribution.conf lacks '{line}'"
    for rel in ("usr/lib/wsl/oobe.sh", "usr/lib/wsl/omarchy.ico", "usr/lib/wsl/terminal-profile.json"):
        size = (rootfs / rel).stat().st_size
        assert 0 < size < WSL_FILE_LIMIT, f"/{rel} is {size} bytes (WSL reads it with a 1 MiB limit)"
    assert (rootfs / "usr/lib/wsl/omarchy.ico").read_bytes()[:4] == b"\x00\x00\x01\x00", "not an ICO file"
    profile = json.loads((rootfs / "usr/lib/wsl/terminal-profile.json").read_text())
    scheme = profile["schemes"][0]["name"]
    assert profile["profiles"][0]["colorScheme"] == scheme
    assert (rootfs / "usr/lib/omarchy-wsl/oobe.sh").is_symlink()
    # The firstboot profile hook is the `wsl --import` fallback (no OOBE there).
    assert (rootfs / "etc/profile.d/00-omarchy-firstboot.sh").is_file()


def test_identity_files(rootfs: Path):
    os_release = (rootfs / "etc/os-release").read_text()
    assert f'PRETTY_NAME="Omarchy {lock("OMARCHY_VERSION")} (WSL)"' in os_release
    assert "VARIANT_ID=wsl" in os_release and "ID_LIKE=arch" in os_release
    assert (rootfs / "usr/share/omarchy-wsl/etc-overrides/os-release").read_text() == os_release
    release = dict(
        line.split("=", 1) for line in (rootfs / "etc/omarchy-wsl-release").read_text().splitlines() if "=" in line
    )
    assert release["OMARCHY_COMMIT"] == lock("OMARCHY_COMMIT")
    assert release["OMARCHY_WSL_GIT_SHA"] == ENV["OMARCHY_WSL_GIT_SHA"]
    assert release["OMARCHY_WSL_VERSION"] == "4.5.0-1"


def test_logind_keeps_user_processes(rootfs: Path):
    conf = (rootfs / "etc/systemd/logind.conf.d/10-omarchy-linger.conf").read_text()
    assert re.search(r"^\[Login\]$", conf, re.M) and re.search(r"^KillUserProcesses=no$", conf, re.M)


def test_installer_refuses_missing_sources(tmp_path: Path):
    shutil.copytree(REPO, tmp_path / "repo", ignore=shutil.ignore_patterns(".git", "dist", "__pycache__"))
    manifest = tmp_path / "repo/rootfs.manifest"
    manifest.write_text(manifest.read_text() + "pkg file 0644 wsl/does-not-exist.conf /etc/x.conf\n")
    result = subprocess.run(["bash", "scripts/install-manifest.sh", "list"], cwd=tmp_path / "repo",
                            capture_output=True, text=True)
    assert result.returncode != 0 and "matches nothing" in result.stderr


def test_install_requires_destdir():
    result = subprocess.run(["make", "--no-print-directory", "install-rootfs"], cwd=REPO, env=ENV,
                            capture_output=True, text=True)
    assert result.returncode != 0


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
