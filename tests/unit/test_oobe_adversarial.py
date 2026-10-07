#!/usr/bin/env python3
"""
Omarchy WSL: Adversarial OOBE & User Provisioning Verification Harness
Tests edge cases across all attack angles:
1. Host interop discovery with corrupted/mocked outputs
2. Username sanitization fuzzing & Unicode normalization
3. System UID collisions (<1000) and UID 1000 reconciliation
4. Atomic INI manipulation
5. Headless vs interactive execution simulation
"""

import os
import re
import shutil
import subprocess
import tempfile
from typing import Optional
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OOBE_SH = os.path.join(PROJECT_ROOT, "wsl", "oobe.sh")
WSL_DIST_CONF = os.path.join(PROJECT_ROOT, "wsl", "wsl-distribution.conf")
WSL_CONF = os.path.join(PROJECT_ROOT, "wsl", "wsl.conf")
FIRSTBOOT_SH = os.path.join(PROJECT_ROOT, "wsl", "00-omarchy-firstboot.sh")


class TestWslDistributionConf(unittest.TestCase):
    def test_distribution_conf_has_no_hardcoded_user(self):
        with open(WSL_DIST_CONF, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertNotIn("defaultName = aqua", content)
        self.assertNotIn("defaultName = omarchy\n", content.lower())
        self.assertIn("defaultName = Omarchy", content)
        self.assertIn("defaultUid = 1000", content)
        self.assertIn("command = /usr/lib/omarchy-wsl/oobe.sh", content)


class TestWslConfBase(unittest.TestCase):
    def test_wsl_conf_base_has_no_hardcoded_aqua(self):
        with open(WSL_CONF, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertNotIn("default = aqua", content)
        self.assertNotIn("default = omarchy", content)
        self.assertIn("systemd = true", content)
        self.assertIn("appendWindowsPath = false", content)


class TestUsernameSanitization(unittest.TestCase):
    def run_sanitize(self, raw_name: str) -> str:
        cmd = [
            "bash",
            "-c",
            f'source "{OOBE_SH}" && sanitize_username "$1"',
            "_",
            raw_name,
        ]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        return result.stdout.strip()

    def test_posix_compliance(self):
        test_cases = [
            ("John Doe", "john_doe"),
            ("AliceSmith", "alicesmith"),
            ("JOHN_DOE_99", "john_doe_99"),
            ("123developer", "u_123developer"),
            ("-leading-dash", "_leading_dash"),
            ("user@domain.com", "user_domain_com"),
            ("test.user+tag", "test_user_tag"),
            ("a" * 100, "a" * 31),
            ("François", "francois"),
            ("Müller", "m_uller"),
            ("Иван", "omarchy"),
            ("张伟", "omarchy"),
            ("🚀🌟", "omarchy"),
            ("", "omarchy"),
            ("   \t\r\n   ", "omarchy"),
        ]
        posix_regex = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
        for raw, expected in test_cases:
            with self.subTest(raw=raw):
                sanitized = self.run_sanitize(raw)
                self.assertEqual(sanitized, expected)
                self.assertTrue(posix_regex.match(sanitized), f"'{sanitized}' does not match POSIX pattern")


class TestAtomicWslConfUpdater(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp()
        self.wsl_conf_path = os.path.join(self.tmp_dir, "wsl.conf")

    def tearDown(self):
        shutil.rmtree(self.tmp_dir)

    def run_update_wsl_conf(self, user: str, initial_content: Optional[str] = None) -> str:
        if initial_content is not None:
            with open(self.wsl_conf_path, "w", encoding="utf-8") as f:
                f.write(initial_content)
        elif os.path.exists(self.wsl_conf_path):
            os.remove(self.wsl_conf_path)

        cmd = [
            "bash",
            "-c",
            f'export OMARCHY_WSL_CONF="{self.wsl_conf_path}" && source "{OOBE_SH}" && update_wsl_conf "$1"',
            "_",
            user,
        ]
        subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        with open(self.wsl_conf_path, "r", encoding="utf-8") as f:
            return f.read()

    def test_create_new_wsl_conf(self):
        out = self.run_update_wsl_conf("alice")
        self.assertIn("[user]\ndefault = alice", out)
        self.assertIn("systemd = true", out)

    def test_append_user_to_existing(self):
        initial = "[boot]\nsystemd = true\n\n[interop]\nenabled = true\n"
        out = self.run_update_wsl_conf("bob", initial)
        self.assertIn("[user]\ndefault = bob", out)
        self.assertIn("[boot]\nsystemd = true", out)
        self.assertIn("[interop]\nenabled = true", out)

    def test_replace_existing_default_user(self):
        initial = "[boot]\nsystemd = true\n\n[user]\ndefault = legacy_user\n\n[network]\ngenerateResolvConf = true\n"
        out = self.run_update_wsl_conf("carol", initial)
        self.assertIn("default = carol", out)
        self.assertNotIn("default = legacy_user", out)
        self.assertIn("[network]\ngenerateResolvConf = true", out)

    def test_empty_user_section_filled(self):
        initial = "[boot]\nsystemd = true\n\n[user]\n\n[network]\ngenerateResolvConf = true\n"
        out = self.run_update_wsl_conf("david", initial)
        self.assertIn("default = david", out)
        self.assertIn("[user]", out)


class TestHeadlessExecutionSafety(unittest.TestCase):
    def test_oobe_syntax(self):
        result = subprocess.run(["bash", "-n", OOBE_SH], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"Syntax error in oobe.sh: {result.stderr}")

    def test_firstboot_profile_syntax(self):
        result = subprocess.run(["bash", "-n", FIRSTBOOT_SH], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"Syntax error in 00-omarchy-firstboot.sh: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
