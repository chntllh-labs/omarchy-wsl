"""upstream.lock is the single pin set; everything that repeats a pin must agree."""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
LOCK_LINE = re.compile(r"^[A-Z0-9_]+=[^\s]*$")


def read_lock() -> dict[str, str]:
    values = {}
    for line in (REPO / "upstream.lock").read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        assert LOCK_LINE.match(line), f"malformed upstream.lock line: {line!r}"
        key, value = line.split("=", 1)
        assert key not in values, f"duplicate key {key}"
        values[key] = value
    return values


LOCK = read_lock()
PKGBUILD = (REPO / "packages/PKGBUILDs/omarchy-wsl/PKGBUILD").read_text()


def pkgbuild_var(name: str) -> str:
    match = re.search(rf"^{name}=['\"]?([^'\"\n]+)['\"]?$", PKGBUILD, re.M)
    assert match, f"PKGBUILD has no {name}"
    return match.group(1)


def test_required_keys_present():
    for key in (
        "OMARCHY_TAG", "OMARCHY_VERSION", "OMARCHY_COMMIT", "OMARCHY_SOURCE_URL", "OMARCHY_SOURCE_SHA256",
        "OMARCHY_CHANNEL", "OMARCHY_REPO_URL", "OMARCHY_KEY_FPR", "OMARCHY_KEY_FILE",
        "ALARM_ROOTFS_URL", "ALARM_KEY_FPR", "ALARM_KEY_FILE",
        "ARCH_BOOTSTRAP_URL", "ARCH_BOOTSTRAP_KEY_FPR", "ARCH_BOOTSTRAP_KEY_FILE",
        "OMARCHY_MIRROR_AARCH64", "OMARCHY_MIRROR_X86_64",
    ):
        assert LOCK.get(key), f"upstream.lock lacks {key}"


def test_pins_are_well_formed():
    assert re.fullmatch(r"[0-9a-f]{40}", LOCK["OMARCHY_COMMIT"])
    assert re.fullmatch(r"[0-9a-f]{64}", LOCK["OMARCHY_SOURCE_SHA256"])
    for key in ("OMARCHY_KEY_FPR", "ALARM_KEY_FPR", "ARCH_BOOTSTRAP_KEY_FPR"):
        assert re.fullmatch(r"[0-9A-F]{40}", LOCK[key]), key
    assert LOCK["OMARCHY_TAG"] == f"v{LOCK['OMARCHY_VERSION']}"
    for key, value in LOCK.items():
        if key.endswith("_URL") or key.startswith("OMARCHY_MIRROR"):
            assert value.startswith("https://"), f"{key} must be HTTPS: {value}"


def test_brief_pins():
    assert LOCK["OMARCHY_TAG"] == "v4.5.0"
    assert LOCK["OMARCHY_COMMIT"].startswith("a948d8a6")
    assert LOCK["OMARCHY_KEY_FPR"] == "40DFB630FF42BCFFB047046CF0134EE680CAC571"
    assert LOCK["ALARM_KEY_FPR"] == "68B3537F39A313B3E574D06777193F152BDBE6A6"
    assert LOCK["ARCH_BOOTSTRAP_KEY_FPR"] == "3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C"
    assert LOCK["OMARCHY_REPO_URL"] == "https://pkgs.omarchy.org/stable/$arch"
    assert LOCK["ALARM_ROOTFS_URL"] == "https://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"


def test_pkgbuild_matches_lock():
    assert pkgbuild_var("_commit") == LOCK["OMARCHY_COMMIT"]
    assert pkgbuild_var("_tag") == LOCK["OMARCHY_TAG"]
    assert pkgbuild_var("pkgver") == LOCK["OMARCHY_VERSION"]
    assert pkgbuild_var("_source_sha256") == LOCK["OMARCHY_SOURCE_SHA256"]
    assert "provides=(\"omarchy=${pkgver}\")" in PKGBUILD
    for conflict in ("'omarchy'", "'omarchy-settings'"):
        assert conflict in PKGBUILD.split("conflicts=(", 1)[1].split(")", 1)[0]
    depends = PKGBUILD.split("depends=(", 1)[1].split(")", 1)[0]
    for desktop in ("hyprland", "sddm", "limine", "snapper", "uwsm", "quickshell"):
        assert desktop not in depends, f"omarchy-wsl must not depend on {desktop}"


@pytest.mark.parametrize("arch", ["aarch64", "x86_64"])
def test_pacman_templates_match_lock(arch: str):
    conf = (REPO / f"wsl/pacman/pacman.conf.{arch}").read_text()
    sections = re.findall(r"^\[([^\]]+)\]", conf, re.M)
    assert sections[0] == "options" and sections[1] == "omarchy", "[omarchy] must come right after [options]"
    assert "aur" not in sections
    assert f"Server = {LOCK['OMARCHY_REPO_URL']}" in conf
    assert re.search(r"^SigLevel = Required DatabaseOptional$", conf, re.M)
    options = conf.split("[omarchy]", 1)[0]
    for directive in ("NoExtract", "ParallelDownloads", "DownloadUser"):
        assert re.search(rf"^{directive}\b", options, re.M), f"{directive} must sit under [options]"
    assert "DisableSandbox" not in conf, "the shipped pacman.conf keeps the sandbox on"
    mirrors = [line.split("=", 1)[1].strip() for line in (REPO / f"wsl/pacman/mirrorlist.{arch}").read_text().splitlines()
               if line.startswith("Server")]
    assert mirrors[0] == LOCK[f"OMARCHY_MIRROR_{arch.upper()}"]
    assert all(m.startswith("https://") for m in mirrors), "mirrors must be HTTPS"


def test_containerfile_reads_pins_from_lock():
    containerfile = (REPO / "Containerfile").read_text()
    for key in ("ALARM_ROOTFS_URL", "ALARM_KEY_FPR", "ARCH_BOOTSTRAP_URL", "ARCH_BOOTSTRAP_KEY_FPR"):
        assert f"lock {key}" in containerfile
    assert "gpgv --keyring" in containerfile
    assert "org.opencontainers.image.source=\"https://github.com/chntllh-labs/omarchy-wsl\"" in containerfile


@pytest.mark.parametrize("prefix", ["OMARCHY", "ALARM", "ARCH_BOOTSTRAP"])
def test_vendored_key_fingerprints(prefix: str):
    gpg = shutil.which("gpg")
    if not gpg:
        pytest.skip("gpg not installed")
    key_file = REPO / LOCK[f"{prefix}_KEY_FILE"]
    assert key_file.is_file(), key_file
    with tempfile.TemporaryDirectory() as home:
        out = subprocess.run([gpg, "--homedir", home, "--batch", "--show-keys", "--with-colons", str(key_file)],
                             capture_output=True, text=True, check=True).stdout
    fprs = [line.split(":")[9] for line in out.splitlines() if line.startswith("fpr:")]
    assert fprs and fprs[0] == LOCK[f"{prefix}_KEY_FPR"], f"{key_file.name}: {fprs[:1]}"
    assert "PRIVATE" not in key_file.read_text()
