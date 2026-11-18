#!/usr/bin/env python3
"""
Omarchy-WSL memory governance: host .wslconfig sizing and guest sysctl tunables.

The .wslconfig tests run the real generator, tools/generate-wslconfig.ps1, under
pwsh with its test seams (-DryRun -Quiet -HostMemoryGB ... -WslConfigPath) and
check the file it would write. They skip when pwsh is not installed (the CI
image has it; strict runners treat a skip as a failure).

cgroup slices and omarchy-build are covered by tests/test_build_governance.sh.
"""

import configparser
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR = REPO_ROOT / "tools" / "generate-wslconfig.ps1"
EXAMPLE = REPO_ROOT / "wsl" / "wslconfig.example"

# Key -> section, verified on 2026-11-18 against
# https://learn.microsoft.com/en-us/windows/wsl/wsl-config (page dated 2026-10-16)
# and microsoft/WSL src/windows/common/WslCoreConfig.h.
VERIFIED_SECTION = {
    "memory": "wsl2", "processors": "wsl2", "swap": "wsl2",
    "nestedVirtualization": "wsl2", "guiApplications": "wsl2", "vmIdleTimeout": "wsl2",
    "networkingMode": "wsl2", "dnsTunneling": "wsl2", "firewall": "wsl2", "autoProxy": "wsl2",
    "localhostForwarding": "wsl2",
    "instanceIdleTimeout": "general",
    "autoMemoryReclaim": "experimental", "sparseVhd": "experimental",
    "hostAddressLoopback": "experimental", "ignoredPorts": "experimental",
}


def parse_wslconfig(text: str) -> configparser.ConfigParser:
    """strict=True rejects duplicate sections and duplicate keys."""
    cp = configparser.ConfigParser(strict=True, interpolation=None, comment_prefixes=("#",),
                                   inline_comment_prefixes=None, delimiters=("=",))
    cp.optionxform = str  # keep key case
    cp.read_string(text)
    return cp


def generate(memory_gb, processors=16, arch="x64", build=26100, *extra):
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        pytest.skip("pwsh is not installed: cannot run tools/generate-wslconfig.ps1")
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / ".wslconfig"  # does not exist: a fresh file is generated
        cmd = [pwsh, "-NoProfile", "-NonInteractive", "-File", str(GENERATOR), "-DryRun", "-Quiet",
               "-HostMemoryGB", str(memory_gb), "-HostLogicalProcessors", str(processors),
               "-HostArch", arch, "-HostBuild", str(build), "-WslConfigPath", str(target), *extra]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert not target.exists(), "-DryRun must not write the file"
    return parse_wslconfig(proc.stdout), proc.stdout


@pytest.mark.parametrize("ram,memory,swap", [
    (4, "2GB", "4GB"),
    (8, "4GB", "4GB"),
    (16, "8GB", "4GB"),
    (32, "24GB", "8GB"),
    (64, "48GB", "16GB"),
    (128, "112GB", "16GB"),
])
def test_auto_sizing_from_host_ram(ram, memory, swap):
    cp, _ = generate(ram, 12)
    assert cp["wsl2"]["memory"] == memory
    assert cp["wsl2"]["swap"] == swap
    assert cp["wsl2"]["processors"] == "12"


def test_64gb_arm64_desktop_host():
    cp, text = generate(64, 18, "arm64", 26100)
    wsl2 = cp["wsl2"]
    assert (wsl2["memory"], wsl2["swap"], wsl2["processors"]) == ("48GB", "16GB", "18")
    assert "nestedVirtualization" not in wsl2, "never on ARM64"
    assert "localhostForwarding" not in wsl2, "ignored by WSL in mirrored mode"
    assert wsl2["networkingMode"] == "mirrored"
    assert wsl2["guiApplications"] == "true"
    assert "vmIdleTimeout" not in wsl2 and not cp.has_section("general")
    exp = cp["experimental"]
    assert exp["autoMemoryReclaim"] == "gradual"
    assert exp["sparseVhd"] == "false"
    assert exp["hostAddressLoopback"] == "true"
    assert exp["ignoredPorts"] == "5353,5355"
    assert "pageReporting" not in text


def test_server_profile_disables_both_idle_timeouts():
    cp, _ = generate(64, 18, "arm64", 26100, "-Profile", "Server")
    assert cp["wsl2"]["vmIdleTimeout"] == "-1"
    assert cp["general"]["instanceIdleTimeout"] == "-1", "without it the distro stops ~15 s after the last session"
    assert cp["wsl2"]["guiApplications"] == "false"
    assert cp["wsl2"]["memory"] == "48GB"


def test_nat_fallback_before_windows_11_22h2():
    cp, _ = generate(16, 8, "x64", 19045)
    wsl2 = cp["wsl2"]
    assert wsl2["networkingMode"] == "NAT"
    assert wsl2["localhostForwarding"] == "true"
    assert "nestedVirtualization" not in wsl2, "Windows 11 only"
    assert "hostAddressLoopback" not in cp["experimental"]
    assert "ignoredPorts" not in cp["experimental"]


@pytest.mark.parametrize("args,expected", [
    (("-HardwarePreset", "Workstation-64GB"), "28GB"),   # 32GB host minus the 4GB Windows reserve
    (("-RamOverrideGB", "100"), "28GB"),
    (("-WindowsReserveGB", "12"), "20GB"),
])
def test_memory_is_clamped_to_host_ram_minus_reserve(args, expected):
    cp, _ = generate(32, 8, "x64", 26100, *args)
    assert cp["wsl2"]["memory"] == expected


def test_overrides_are_clamped():
    cp, _ = generate(32, 16, "x64", 26100, "-CpuOverride", "64", "-SwapOverrideGB", "1")
    assert cp["wsl2"]["processors"] == "16"
    assert cp["wsl2"]["swap"] == "4GB", "swap is never below 4GB"


@pytest.mark.parametrize("arch,build,extra", [
    ("x64", 26100, ()), ("arm64", 26100, ()), ("x64", 19045, ()),
    ("x64", 26100, ("-ForceNAT",)), ("arm64", 22631, ("-Profile", "Server")), ("x64", 22000, ("-Profile", "Server")),
])
def test_every_emitted_key_is_in_its_verified_section(arch, build, extra):
    cp, _ = generate(32, 8, arch, build, *extra)
    for section in cp.sections():
        for key in cp[section]:
            assert key in VERIFIED_SECTION, f"unexpected key {key}"
            assert VERIFIED_SECTION[key] == section, f"{key} must be in [{VERIFIED_SECTION[key]}], not [{section}]"


def test_example_matches_generator_output():
    """wsl/wslconfig.example documents the output for a 32 GB x64 Windows 11 host."""
    cp, _ = generate(32, 16, "x64", 26100)
    example = parse_wslconfig(EXAMPLE.read_text(encoding="utf-8"))
    as_dict = lambda c: {s: dict(c[s]) for s in c.sections()}
    assert as_dict(example) == as_dict(cp)


def test_example_has_no_misplaced_or_unsafe_keys():
    example = parse_wslconfig(EXAMPLE.read_text(encoding="utf-8"))
    assert "autoMemoryReclaim" not in example["wsl2"]
    assert "sparseVhd" not in example["wsl2"]
    assert example["experimental"]["sparseVhd"] == "false"
    assert "pageReporting" not in example["wsl2"]


def test_guest_sized_bash_generator_is_gone():
    """The .sh sized memory from the guest's /proc/meminfo and shrank on every run."""
    assert not (REPO_ROOT / "tools" / "generate-wslconfig.sh").exists()


# -----------------------------------------------------------------------------
# Guest sysctl tunables (incident 2026-09-10: slab starvation)
# -----------------------------------------------------------------------------
SYSCTL_FILES = ["99-omarchy-wsl.conf", "99-zz-omarchy-wsl-stability.conf"]


def sysctl_file(name: str) -> Path:
    """The single file with this name under wsl/ (located by name, not by directory)."""
    hits = sorted((REPO_ROOT / "wsl").rglob(name))
    assert len(hits) == 1, f"expected exactly one {name} under wsl/, found {hits}"
    return hits[0]


def parse_sysctl(path: Path) -> dict:
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith(("#", ";")) and "=" in line:
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    return data


@pytest.mark.parametrize("filename", SYSCTL_FILES)
def test_vfs_cache_pressure_is_100(filename):
    """50 stops dentry/inode reclaim: slab bloat and kswapd0 order:0 failures."""
    assert parse_sysctl(sysctl_file(filename)).get("vm.vfs_cache_pressure") == "100"


@pytest.mark.parametrize("filename", SYSCTL_FILES)
def test_swappiness_is_10(filename):
    assert parse_sysctl(sysctl_file(filename)).get("vm.swappiness") == "10"


@pytest.mark.parametrize("filename", SYSCTL_FILES)
def test_min_free_kbytes_is_128mb(filename):
    assert parse_sysctl(sysctl_file(filename)).get("vm.min_free_kbytes") == "131072"


@pytest.mark.parametrize("filename", SYSCTL_FILES)
def test_dirty_ratio_pacing(filename):
    sysctls = parse_sysctl(sysctl_file(filename))
    assert sysctls.get("vm.dirty_ratio") == "10"
    assert sysctls.get("vm.dirty_background_ratio") == "5"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
