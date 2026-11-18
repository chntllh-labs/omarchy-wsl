#!/usr/bin/env python3
"""Omarchy WSL: OOBE and owner-account library tests (pytest).

Every test drives the REAL shell code: lib/omarchy-wsl-account.sh (sourced by
wsl/oobe.sh and bin/omarchy-rename-owner) and the CLI entry points, through
bash. Expected values are exact and must be identical on Linux (glibc, bash 5)
and macOS (bash 3.2): the transliteration uses an explicit table plus Python
NFKD, never iconv //TRANSLIT, so the locale cannot change a user name.

Run from the repository root:  python3 -m pytest -q tests/unit/test_oobe_adversarial.py
"""

import os
import re
import shutil
import subprocess
import tempfile

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ACCOUNT_LIB = os.path.join(ROOT, "lib", "omarchy-wsl-account.sh")
OOBE = os.path.join(ROOT, "wsl", "oobe.sh")
RENAME = os.path.join(ROOT, "bin", "omarchy-rename-owner")
HOOK = os.path.join(ROOT, "wsl", "profile.d", "00-omarchy-firstboot.sh")
USER_CONF_TEMPLATE = os.path.join(ROOT, "wsl", "omarchy-user.conf")

STRICT_NAME = re.compile(r"^[a-z_][a-z0-9_-]{0,30}$")


def bash(script, *args, env=None, input_text=None):
    """Run `script` in bash with the account library sourced; $1.. = args."""
    full_env = dict(os.environ)
    full_env.update({"NO_COLOR": "1", "OMARCHY_NOW": "2026-01-01T00:00:00Z"})
    for k in ("OMARCHY_TRANSLIT", "OMARCHY_PASSWD_ROOT", "OMARCHY_USER_CONF_TEMPLATE"):
        full_env.pop(k, None)
    if env:
        full_env.update(env)
    return subprocess.run(
        ["bash", "-c", 'source "$0" && ' + script, ACCOUNT_LIB, *args],
        capture_output=True, text=True, env=full_env, input=input_text, check=False,
    )


def sanitize(raw, mode="auto", locale=None):
    env = {"OMARCHY_TRANSLIT": mode}
    if locale:
        env["LC_ALL"] = locale
    r = bash('sanitize_username "$1"', raw, env=env)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


# -----------------------------------------------------------------------------
# Distribution files
# -----------------------------------------------------------------------------
class TestDistributionFiles:
    def read(self, *parts):
        with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
            return f.read()

    def test_wsl_distribution_conf_runs_the_oobe_for_uid_1000(self):
        conf = self.read("wsl", "wsl-distribution.conf")
        assert re.search(r"^command = /usr/lib/wsl/oobe\.sh$", conf, re.M)
        assert re.search(r"^defaultUid = 1000$", conf, re.M)
        assert re.search(r"^defaultName = Omarchy$", conf, re.M)

    def test_base_wsl_conf_names_no_user(self):
        conf = self.read("wsl", "wsl.conf")
        assert not re.search(r"^\s*default\s*=", conf, re.M)
        assert "systemd = true" in conf
        assert "appendWindowsPath = false" in conf

    def test_user_conf_template_has_no_preseed_and_empty_home_dirs(self):
        conf = self.read("wsl", "omarchy-user.conf")
        assert not re.search(r"^\s*DEFAULT_USER\s*=", conf, re.M)
        assert re.search(r'^OMARCHY_HOME_DIRS=""$', conf, re.M)

    def test_duplicate_firstboot_hook_removed(self):
        assert not os.path.exists(os.path.join(ROOT, "wsl", "00-omarchy-firstboot.sh"))
        assert os.path.exists(HOOK)

    @pytest.mark.parametrize("path", [OOBE, ACCOUNT_LIB, RENAME])
    def test_no_locale_dependent_or_destructive_calls(self, path):
        with open(path, encoding="utf-8") as f:
            code = [ln for ln in f.read().splitlines() if not ln.lstrip().startswith("#")]
        text = "\n".join(code)
        assert "iconv" not in text
        assert not re.search(r"passwd\s+-d\b", text)
        assert not re.search(r"%wheel[^\n]*NOPASSWD", text)
        assert not re.search(r"\bpkill\b", text)


# -----------------------------------------------------------------------------
# Transliteration ("suggest" mode) — exact outputs on every OS and locale
# -----------------------------------------------------------------------------
SANITIZE_VECTORS = [
    ("Müller", "muller"),
    ("François", "francois"),
    ("José", "jose"),
    ("John Doe", "john_doe"),
    ("AliceSmith", "alicesmith"),
    ("JOHN_DOE_99", "john_doe_99"),
    ("123developer", "u_123developer"),
    ("-leading-dash", "leading-dash"),
    ("jean-luc", "jean-luc"),
    ("john - doe", "john_doe"),
    ("user@domain.com", "user_domain_com"),
    ("test.user+tag", "test_user_tag"),
    ("Straße", "strasse"),
    ("Ærøskøbing", "aeroskobing"),
    ("Søren Kierkegaard", "soren_kierkegaard"),
    ("Łukasz Żółć", "lukasz_zolc"),
    ("Đorđe", "dorde"),
    ("Şebnem İnce", "sebnem_ince"),
    ("Ðóra Þórsdóttir", "dora_thorsdottir"),
    ("Zoë", "zoe"),
    ("Иван", "omarchy"),
    ("张伟", "omarchy"),
    ("🚀🌟", "omarchy"),
    ("", "omarchy"),
    ("   \t\r\n   ", "omarchy"),
    ("a" * 100, "a" * 31),
]


class TestSanitize:
    @pytest.mark.parametrize("mode", ["auto", "table"])
    @pytest.mark.parametrize("raw,expected", SANITIZE_VECTORS)
    def test_exact_vectors(self, raw, expected, mode):
        got = sanitize(raw, mode=mode)
        assert got == expected
        assert STRICT_NAME.match(got)

    @pytest.mark.parametrize("locale", ["C", "POSIX", "C.UTF-8"])
    def test_locale_independent(self, locale):
        assert sanitize("Müller François Łukasz", locale=locale) == "muller_francois_lukasz"

    def test_letters_outside_the_table_use_nfkd_when_python_exists(self):
        assert sanitize("Nguyễn") == "nguyen"
        assert sanitize("Ｊｏｈｎ") == "john"  # full-width compatibility form

    def test_table_only_mode_drops_letters_outside_the_table(self):
        assert sanitize("Nguyễn", mode="table") == "nguyn"


# -----------------------------------------------------------------------------
# Strict validation ("reject" mode) and suggestions
# -----------------------------------------------------------------------------
class TestValidate:
    @pytest.mark.parametrize("name", ["alice", "jane-doe", "a", "dev_42", "x" * 31, "omarchy"])
    def test_valid(self, name):
        assert bash('validate_username "$1"', name).returncode == 0

    @pytest.mark.parametrize("name", [
        "", "Root", "root", "daemon", "wheel", "games", "systemd-network", "_apt", "9abc", "-x",
        "a b", "../x", "x/y", "jösé", "x" * 32, "a;rm", "$(id)",
    ])
    def test_invalid(self, name):
        r = bash('validate_username "$1"; rc=$?; printf "%s" "$OMW_ACCT_REASON"; exit $rc', name)
        assert r.returncode == 1
        assert r.stdout  # a human-readable reason is always given

    def test_suggestion_avoids_reserved_and_taken_names(self, tmp_path):
        etc = tmp_path / "etc"
        etc.mkdir()
        (etc / "passwd").write_text("root:x:0:0::/root:/bin/bash\nu_games:x:1001:1001::/home/u:/bin/bash\n")
        (etc / "group").write_text("root:x:0:\ngames:x:50:\n")
        r = bash('suggest_username "$1"', "Games", env={"OMARCHY_PASSWD_ROOT": str(tmp_path)})
        assert r.stdout.strip() == "omarchy"
        r = bash('suggest_username "$1"', "Root", env={"OMARCHY_PASSWD_ROOT": str(tmp_path)})
        assert r.stdout.strip() == "u_root"


# -----------------------------------------------------------------------------
# /etc/wsl.conf [user] default — atomic INI edit, exact results
# -----------------------------------------------------------------------------
WSL_CONF_CASES = [
    ("missing", None, "[user]\ndefault = alice\n"),
    ("append", "[boot]\nsystemd = true\n", "[boot]\nsystemd = true\n\n[user]\ndefault = alice\n"),
    ("replace",
     "[boot]\nsystemd = true\n\n[user]\ndefault = legacy\n\n[network]\ngenerateResolvConf = true\n",
     "[boot]\nsystemd = true\n\n[user]\ndefault = alice\n\n[network]\ngenerateResolvConf = true\n"),
    ("empty-section", "[user]\n[network]\nx = 1\n", "[user]\ndefault = alice\n[network]\nx = 1\n"),
    ("duplicates", "[user]\ndefault = a\ndefault = b\n", "[user]\ndefault = alice\n"),
    ("case-and-comment", "[User] # owner\nDefault=old\n", "[User] # owner\ndefault = alice\n"),
    ("crlf", "[boot]\r\nsystemd = true\r\n[user]\r\ndefault = old\r\n",
     "[boot]\r\nsystemd = true\r\n[user]\r\ndefault = alice\n"),
    ("other-key-kept", "[user]\nfoo = bar\n", "[user]\nfoo = bar\ndefault = alice\n"),
]


class TestWslConf:
    @pytest.mark.parametrize("label,initial,expected", WSL_CONF_CASES, ids=[c[0] for c in WSL_CONF_CASES])
    def test_update(self, tmp_path, label, initial, expected):
        conf = tmp_path / "wsl.conf"
        if initial is not None:
            conf.write_bytes(initial.encode())
        r = bash('update_wsl_conf_default_user "$1"', "alice", env={"OMARCHY_WSL_CONF": str(conf)})
        assert r.returncode == 0, r.stderr
        assert conf.read_bytes().decode() == expected
        assert oct(conf.stat().st_mode & 0o777) == "0o644"
        assert [p.name for p in tmp_path.iterdir()] == ["wsl.conf"]  # no temp files left

    def test_refuses_invalid_names(self, tmp_path):
        conf = tmp_path / "wsl.conf"
        conf.write_text("[user]\ndefault = keep\n")
        r = bash('update_wsl_conf_default_user "$1"', "bad name", env={"OMARCHY_WSL_CONF": str(conf)})
        assert r.returncode != 0
        assert conf.read_text() == "[user]\ndefault = keep\n"

    def test_reader(self, tmp_path):
        conf = tmp_path / "wsl.conf"
        conf.write_text('[boot]\ndefault = no\n[USER]\n default = "bob" \n')
        r = bash("wsl_conf_default_user", env={"OMARCHY_WSL_CONF": str(conf)})
        assert r.stdout.strip() == "bob"


# -----------------------------------------------------------------------------
# key=value configuration: parsed, never sourced
# -----------------------------------------------------------------------------
class TestKeyValue:
    def test_reader_rules(self, tmp_path):
        f = tmp_path / "c.conf"
        f.write_bytes(b"# DEFAULT_USER=commented\nDEFAULT_USER=first\n  DEFAULT_USER = 'second'\r\nOTHER=\"a b\"\n")
        assert bash('omw_kv_get "$1" DEFAULT_USER', str(f)).stdout.strip() == "second"
        assert bash('omw_kv_get "$1" OTHER', str(f)).stdout.strip() == "a b"
        assert bash('omw_kv_get "$1" MISSING', str(f)).returncode == 1

    def test_reader_never_executes(self, tmp_path):
        marker = tmp_path / "pwned"
        f = tmp_path / "c.conf"
        f.write_text('DEFAULT_USER=$(touch %s)\nX=`touch %s`\n' % (marker, marker))
        r = bash('omw_kv_get "$1" DEFAULT_USER; omw_kv_get "$1" X', str(f))
        assert not marker.exists()
        assert r.stdout.splitlines() == ["$(touch %s)" % marker, "`touch %s`" % marker]
        r = bash("user_conf_default_user", env={"OMARCHY_USER_CONF": str(f)})
        assert r.stdout == ""  # an invalid name is ignored, with a warning
        assert "Ignoring DEFAULT_USER" in r.stderr

    def test_writer_refuses_unsafe_values(self, tmp_path):
        f = tmp_path / "c.conf"
        for value in ("$(id)", "a`b", 'q"x', "back\\slash", "new\nline"):
            assert bash('omw_kv_set "$1" KEY "$2"', str(f), value).returncode == 2
        assert not f.exists()

    def test_home_dirs_whitelist(self, tmp_path):
        f = tmp_path / "user.conf"
        f.write_text('OMARCHY_HOME_DIRS="code notes/2026 ../evil /abs a/../b .config"\n')
        r = bash("user_conf_home_dirs", env={"OMARCHY_USER_CONF": str(f)})
        assert r.stdout.splitlines() == ["code", "notes/2026"]
        assert "../evil" in r.stderr and "/abs" in r.stderr


# -----------------------------------------------------------------------------
# Sentinel and /etc/omarchy-user.conf
# -----------------------------------------------------------------------------
class TestStateFiles:
    def test_sentinel_exact_content(self, tmp_path):
        r = bash("write_sentinel devuser", env={"OMARCHY_SENTINEL_DIR": str(tmp_path)})
        assert r.returncode == 0, r.stderr
        assert (tmp_path / "oobe_completed").read_text() == (
            "# Omarchy-WSL OOBE completion sentinel. Identity is keyed on PROVISIONED_UID;\n"
            "# PROVISIONED_USER is informational. Parsed, never sourced.\n"
            "OOBE_VERSION=2.0.0\nPROVISIONED_UID=1000\nPROVISIONED_USER=devuser\n"
            "WRITTEN_BY=oobe\nCOMPLETED_AT=2026-01-01T00:00:00Z\n"
        )
        env = {"OMARCHY_SENTINEL_DIR": str(tmp_path)}
        assert bash("sentinel_provisioned", env=env).returncode == 0
        assert bash("sentinel_get PATH", env=env).returncode == 2

    def test_user_conf_keeps_other_lines(self, tmp_path):
        f = tmp_path / "omarchy-user.conf"
        f.write_text('# keep me\nOMARCHY_HOME_DIRS="code"\nDEFAULT_USER=old\nDEFAULT_USER=older\n')
        r = bash("write_user_conf jane", env={"OMARCHY_USER_CONF": str(f)})
        assert r.returncode == 0, r.stderr
        assert f.read_text() == '# keep me\nOMARCHY_HOME_DIRS="code"\nDEFAULT_USER=jane\n'

    def test_user_conf_seeded_from_template(self, tmp_path):
        f = tmp_path / "omarchy-user.conf"
        r = bash("write_user_conf jane", env={"OMARCHY_USER_CONF": str(f),
                                              "OMARCHY_USER_CONF_TEMPLATE": USER_CONF_TEMPLATE})
        assert r.returncode == 0, r.stderr
        text = f.read_text()
        with open(USER_CONF_TEMPLATE, encoding="utf-8") as t:
            assert text == t.read() + "DEFAULT_USER=jane\n"


# -----------------------------------------------------------------------------
# CLI contracts (exit codes) and the profile hook
# -----------------------------------------------------------------------------
def run(*argv, env_extra=None):
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    for k in ("OMARCHY_ALLOW_NONROOT", "CI", "DEBIAN_FRONTEND"):
        env.pop(k, None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(list(argv), capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL, check=False)


def as_unprivileged(argv):
    """argv that runs without root: as is for non-root, via setpriv otherwise."""
    if os.geteuid() != 0:
        return argv
    setpriv = shutil.which("setpriv")
    if not setpriv:
        pytest.fail("running as root without setpriv: cannot exercise the non-root path")
    return [setpriv, "--reuid=65534", "--regid=65534", "--clear-groups", *argv]


class TestCli:
    @pytest.mark.parametrize("tool,usage", [(OOBE, "Usage: oobe.sh"), (RENAME, "Usage: omarchy-rename-owner")])
    def test_help_and_version(self, tool, usage):
        r = run("bash", tool, "--help")
        assert r.returncode == 0 and usage in r.stdout
        r = run("bash", tool, "--version")
        assert r.returncode == 0 and r.stdout.strip()

    @pytest.mark.parametrize("tool", [OOBE, RENAME])
    def test_unknown_option_is_usage_error(self, tool):
        r = run("bash", tool, "--definitely-not-an-option", "x")
        assert r.returncode == 2
        assert "Usage:" in r.stderr and r.stdout == ""

    def test_oobe_rejects_positional_and_valueless_user(self):
        assert run("bash", OOBE, "stray").returncode == 2
        assert run("bash", OOBE, "--user").returncode == 2

    def test_oobe_requires_root(self):
        r = run(*as_unprivileged(["bash", OOBE, "--headless", "--user", "devuser"]))
        assert r.returncode == 3
        assert "wsl.exe -d Omarchy -u root -- /usr/lib/wsl/oobe.sh" in r.stderr

    def test_rename_requires_root_with_the_exact_hint(self):
        r = run(*as_unprivileged(["bash", RENAME, "-y", "jane"]))
        assert r.returncode == 3
        assert "wsl.exe -d Omarchy -u root -- omarchy-rename-owner -y jane" in r.stderr

    def test_profile_hook_is_posix_and_inert_without_a_root_terminal(self):
        sh = shutil.which("dash") or "sh"
        assert run(sh, "-n", HOOK).returncode == 0
        r = run(sh, "-c", '. "$0"; echo alive', HOOK)
        assert r.returncode == 0 and r.stdout.strip() == "alive"
