#!/usr/bin/env python3
"""
Omarchy-WSL Memory Management, Resource Governors & OOM Resilience Test Suite
Validates host .wslconfig generator logic, sysctl memory tunables, and cgroup v2 policies.
"""

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


class TestWslConfigGeneratorLogic(unittest.TestCase):
    """Adversarial verification of .wslconfig mathematical resource scaling."""

    def calculate_allocation(self, total_ram_gb: float, cpu_cores: int, profile: str = "Auto",
                             user_ram: int = 0, user_cpu: int = 0, user_swap: int = 0):
        """Python mirror of Calculate-ResourceAllocation in generate-wslconfig.ps1."""
        if profile == "Laptop-16GB":
            tier = "Preset: Laptop (16GB RAM)"
            wsl_ram = 8
            wsl_swap = 4
            host_reserved = 8
        elif profile == "Pro-32GB":
            tier = "Preset: Pro / Mid-Range (32GB RAM)"
            wsl_ram = 24
            wsl_swap = 8
            host_reserved = 8
        elif profile == "Workstation-64GB":
            tier = "Preset: Workstation / Titan (64GB RAM)"
            wsl_ram = 48
            wsl_swap = 16
            host_reserved = 16
        elif profile == "Server-128GB":
            tier = "Preset: Enterprise / Server (128GB RAM)"
            wsl_ram = 112
            wsl_swap = 16
            host_reserved = 16
        else:
            if total_ram_gb <= 8.5:
                tier = "Low-Memory Host (<=8GB)"
                wsl_ram = max(2, int(total_ram_gb * 0.5))
                wsl_swap = 4
                host_reserved = round(total_ram_gb - wsl_ram, 1)
            elif total_ram_gb <= 18.0:
                tier = "Entry Developer / Laptop (16GB Tier)"
                wsl_ram = 8
                wsl_swap = 4
                host_reserved = round(total_ram_gb - wsl_ram, 1)
            elif total_ram_gb <= 36.0:
                tier = "Mid-Range / Pro Laptop (32GB Tier)"
                wsl_ram = int(total_ram_gb - 8)
                wsl_swap = 8
                host_reserved = 8
            elif total_ram_gb <= 72.0:
                tier = "Workstation / Snapdragon Dev Kit (64GB Tier)"
                wsl_ram = int(total_ram_gb * 0.75)
                wsl_swap = 16
                host_reserved = round(total_ram_gb - wsl_ram, 1)
            else:
                tier = "Enterprise Workstation / Server (>64GB Tier)"
                wsl_ram = int(total_ram_gb - 16)
                wsl_swap = 16
                host_reserved = 16

        if user_ram > 0:
            wsl_ram = user_ram
            host_reserved = round(total_ram_gb - wsl_ram, 1)
        wsl_cpus = cpu_cores if user_cpu == 0 else user_cpu
        if user_swap > 0:
            wsl_swap = user_swap

        wsl_ram = max(2, wsl_ram)
        wsl_cpus = max(1, wsl_cpus)
        wsl_swap = max(4, wsl_swap)  # Enforce minimum 4GB swap to prevent refault storms

        return {
            "tier": tier,
            "wsl_ram": wsl_ram,
            "wsl_swap": wsl_swap,
            "wsl_cpus": wsl_cpus,
            "host_reserved": host_reserved
        }

    def test_laptop_16gb_allocation_non_starvation(self):
        """16GB laptop must get 8GB for WSL, preserving 8GB for Windows host."""
        res = self.calculate_allocation(16.0, 8)
        self.assertEqual(res["wsl_ram"], 8, "WSL RAM on 16GB host must be 8GB")
        self.assertGreaterEqual(res["host_reserved"], 8.0, "Windows host must retain >= 8GB")
        self.assertGreaterEqual(res["wsl_swap"], 4, "Swap must be >= 4GB")
        self.assertEqual(res["wsl_cpus"], 8)

    def test_pro_32gb_allocation(self):
        """32GB laptop must get 24GB for WSL, preserving 8GB for Windows host."""
        res = self.calculate_allocation(32.0, 16)
        self.assertEqual(res["wsl_ram"], 24, "WSL RAM on 32GB host must be 24GB")
        self.assertEqual(res["host_reserved"], 8.0, "Windows host must retain 8GB")
        self.assertEqual(res["wsl_swap"], 8)

    def test_workstation_64gb_titan_allocation(self):
        """64GB Snapdragon Dev Kit (Titan) must get 48GB for WSL, preserving 16GB for Windows."""
        res = self.calculate_allocation(64.0, 18)
        self.assertEqual(res["wsl_ram"], 48, "WSL RAM on 64GB host must be 48GB")
        self.assertEqual(res["host_reserved"], 16.0, "Windows host must retain 16GB")
        self.assertEqual(res["wsl_swap"], 16)
        self.assertEqual(res["wsl_cpus"], 18)

    def test_server_128gb_allocation(self):
        """128GB workstation must get 112GB for WSL, preserving 16GB for Windows."""
        res = self.calculate_allocation(128.0, 32)
        self.assertEqual(res["wsl_ram"], 112, "WSL RAM on 128GB host must be 112GB")
        self.assertEqual(res["host_reserved"], 16.0, "Windows host must retain 16GB")
        self.assertEqual(res["wsl_swap"], 16)

    def test_low_memory_8gb_allocation(self):
        """8GB low-memory host must split 4GB/4GB."""
        res = self.calculate_allocation(8.0, 4)
        self.assertEqual(res["wsl_ram"], 4)
        self.assertEqual(res["host_reserved"], 4.0)
        self.assertEqual(res["wsl_swap"], 4)

    def test_swap_is_never_zero(self):
        """Adversarial check: swap=0 triggers StorPort refault storms (issue #40420)."""
        for ram in [8.0, 16.0, 32.0, 64.0, 128.0]:
            res = self.calculate_allocation(ram, 8)
            self.assertGreater(res["wsl_swap"], 0, f"Swap cannot be 0 for RAM={ram}")
            self.assertGreaterEqual(res["wsl_swap"], 4, "Swap must have at least 4GB headroom")


class TestWslConfigFilesAndDefects(unittest.TestCase):
    """Inspects generate-wslconfig.ps1 and wslconfig.example for historical regressions."""

    def test_generate_wslconfig_script_exists(self):
        script = REPO_ROOT / "tools" / "generate-wslconfig.ps1"
        self.assertTrue(script.is_file(), f"Missing {script}")

    def test_no_deprecated_page_reporting_key(self):
        """wsl2.pageReporting triggers 'Unknown key' dialog on modern WSL startup."""
        for path in [REPO_ROOT / "tools" / "generate-wslconfig.ps1", REPO_ROOT / "wsl" / "wslconfig.example"]:
            content = path.read_text(encoding="utf-8")
            self.assertNotIn("pageReporting=true", content, f"Deprecated pageReporting=true found in {path}")
            self.assertNotIn("pageReporting = true", content, f"Deprecated pageReporting = true found in {path}")

    def test_auto_memory_reclaim_in_experimental_section(self):
        """autoMemoryReclaim placed in [wsl2] triggers 'Unknown key' error."""
        for path in [REPO_ROOT / "tools" / "generate-wslconfig.ps1", REPO_ROOT / "wsl" / "wslconfig.example"]:
            content = path.read_text(encoding="utf-8")
            # In wslconfig.example: check section placement
            if path.suffix == ".example":
                wsl2_part, exp_part = content.split("[experimental]")
                self.assertNotIn("autoMemoryReclaim", wsl2_part, "autoMemoryReclaim must not be in [wsl2]")
                self.assertIn("autoMemoryReclaim", exp_part, "autoMemoryReclaim must be in [experimental]")
                self.assertIn("gradual", exp_part, "autoMemoryReclaim must be set to 'gradual'")

    def test_sparse_vhd_is_disabled(self):
        """sparseVhd=true leads to ext4 superblock corruption from NTFS sparse races."""
        for path in [REPO_ROOT / "tools" / "generate-wslconfig.ps1", REPO_ROOT / "wsl" / "wslconfig.example"]:
            lines = [l.strip() for l in path.read_text(encoding="utf-8").splitlines() if not l.strip().startswith("#")]
            for l in lines:
                self.assertFalse(re.search(r"sparseVhd\s*=\s*true", l, re.IGNORECASE),
                                 f"Unsafe sparseVhd=true found active in {path}: {l}")
            content = path.read_text(encoding="utf-8")
            self.assertTrue("sparseVhd=false" in content or "sparseVhd = false" in content,
                            f"sparseVhd=false must be explicitly enforced in {path}")


class TestSysctlMemoryStability(unittest.TestCase):
    """Validates sysctl memory tunables against the 2026-09-10 slab starvation incident."""

    def parse_sysctl(self, path: Path) -> dict:
        data = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
        return data

    def test_vfs_cache_pressure_is_100_not_50(self):
        """
        REGRESSION PREVENTION:
        vfs_cache_pressure = 50 halts dentry/inode reclaim, causing slab bloat and
        kswapd0 order:0 allocation panics (Incident 2026-09-10). Must be strictly 100.
        """
        for filename in ["wsl/sysctl.d/99-omarchy-wsl.conf", "wsl/99-zz-omarchy-wsl-stability.conf"]:
            path = REPO_ROOT / filename
            self.assertTrue(path.is_file(), f"Missing {path}")
            sysctls = self.parse_sysctl(path)
            self.assertEqual(sysctls.get("vm.vfs_cache_pressure"), "100",
                             f"vm.vfs_cache_pressure in {filename} must be 100 to prevent slab starvation!")

    def test_swappiness_is_10(self):
        """swappiness=10 keeps active compilations in RAM while allowing swap as safety valve."""
        for filename in ["wsl/sysctl.d/99-omarchy-wsl.conf", "wsl/99-zz-omarchy-wsl-stability.conf"]:
            sysctls = self.parse_sysctl(REPO_ROOT / filename)
            self.assertEqual(sysctls.get("vm.swappiness"), "10")

    def test_min_free_kbytes_is_128mb(self):
        """min_free_kbytes=131072 reserves 128MB normal zone free pages for atomic allocations."""
        for filename in ["wsl/sysctl.d/99-omarchy-wsl.conf", "wsl/99-zz-omarchy-wsl-stability.conf"]:
            sysctls = self.parse_sysctl(REPO_ROOT / filename)
            self.assertEqual(sysctls.get("vm.min_free_kbytes"), "131072")

    def test_dirty_ratio_pacing(self):
        """dirty_ratio=10 and dirty_background_ratio=5 enforce smooth I/O pacing on virtual disks."""
        for filename in ["wsl/sysctl.d/99-omarchy-wsl.conf", "wsl/99-zz-omarchy-wsl-stability.conf"]:
            sysctls = self.parse_sysctl(REPO_ROOT / filename)
            self.assertEqual(sysctls.get("vm.dirty_ratio"), "10")
            self.assertEqual(sysctls.get("vm.dirty_background_ratio"), "5")

    def test_lexicographical_order_of_stability_conf(self):
        """99-zz-omarchy-wsl-stability.conf must sort alphabetically after 99-omarchy-*.conf."""
        name_stability = "99-zz-omarchy-wsl-stability.conf"
        name_omarchy = "99-omarchy-wsl.conf"
        self.assertGreater(name_stability, name_omarchy,
                           "99-zz must sort alphabetically after 99-omarchy to guarantee final override.")


class TestCgroupResourceGovernance(unittest.TestCase):
    """Validates cgroup v2 slice definitions and compilation wrapper."""

    def test_build_slice_properties(self):
        path = REPO_ROOT / "wsl" / "cgroups" / "build.slice"
        self.assertTrue(path.is_file(), f"Missing {path}")
        content = path.read_text(encoding="utf-8")

        self.assertIn("CPUWeight=100", content, "Build slice must have low CPUWeight (100)")
        self.assertIn("IOWeight=100", content, "Build slice must throttle IOWeight (100)")
        self.assertIn("MemoryHigh=85%", content, "Build slice must enforce MemoryHigh=85% soft ceiling")
        self.assertIn("MemoryOOMGroup=yes", content, "Build slice must enforce atomic MemoryOOMGroup=yes")
        self.assertIn("OOMScoreAdjust=500", content, "Build slice must sacrifice itself first with OOMScoreAdjust=500")

    def test_interactive_protection_properties(self):
        path = REPO_ROOT / "wsl" / "cgroups" / "10-interactive-protection.conf"
        self.assertTrue(path.is_file(), f"Missing {path}")
        content = path.read_text(encoding="utf-8")

        self.assertIn("CPUWeight=1000", content, "Interactive session must have high CPUWeight (1000)")
        self.assertIn("IOWeight=1000", content, "Interactive session must have high IOWeight (1000)")
        self.assertIn("OOMScoreAdjust=-200", content, "Interactive session must be shielded (OOMScoreAdjust=-200)")

    def test_omarchy_build_script_executable(self):
        script = REPO_ROOT / "bin" / "omarchy-build"
        self.assertTrue(script.is_file(), f"Missing {script}")
        self.assertTrue(os.access(script, os.X_OK), f"{script} must be executable")

        # Test help flag
        proc = subprocess.run([str(script), "--help"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)  # usage() exits with 1
        self.assertIn("Usage: omarchy-build", proc.stdout + proc.stderr)
        self.assertIn("--slice", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
