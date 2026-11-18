#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: image pipeline suite (sanitiser, leak audit, deterministic export)
# ==============================================================================
# Exercises scripts/strip-rootfs.sh, tests/audit-rootfs-leaks.sh and
# scripts/normalize-rootfs.sh on a synthetic root filesystem, so the export
# guarantees are proven in seconds without building the image:
#   - two independent normalisations of one export are byte-identical
#   - setuid 4755, sticky 1777, numeric uids and security.capability survive
#   - every archived mtime is SOURCE_DATE_EPOCH; runtime files are dropped
#   - a seeded leak makes the audit fail closed (exit 3, no artifact)
#   - the sanitiser keeps libc_nonshared.a/libgcc.a and omarchy-wsl docs, and
#     removes credentials (.config/gh, .netrc, ...) from every home
# Root-only checks (ownership, file capabilities) need root in a container;
# under OMW_STRICT=1 a missing prerequisite is a failure, not a skip.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TESTS_RUN=0 TESTS_PASSED=0 TESTS_FAILED=0 TESTS_SKIPPED=0
pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  [PASS] $*"
}
fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  [FAIL] $*"
}
skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  echo "  [SKIP] $*"
}
header() { echo -e "\n>>> $*"; }
check() {
  local desc="$1"
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/omw-pipeline.XXXXXX")
trap 'rm -rf "$T"' EXIT
EPOCH=1700000000


# A minimal root filesystem that passes the audit.
make_clean_rootfs() {
  local r="$1"
  mkdir -p "$r"/{etc/sudoers.d,etc/ssh,usr/bin,usr/lib,usr/share/doc/omarchy-wsl,root,home,tmp,var/tmp,var/cache/pacman/pkg,var/lib/pacman,var/log}
  printf 'root:x:0:0::/root:/bin/bash\nbin:x:1:1::/:/usr/bin/nologin\n' >"$r/etc/passwd"
  printf 'root:!*:19000::::::\nbin:!*:19000::::::\n' >"$r/etc/shadow"
  : >"$r/etc/machine-id"
  printf '#!/bin/sh\n' >"$r/usr/bin/sudo"
  chmod 4755 "$r/usr/bin/sudo"
  printf 'archive' >"$r/usr/lib/libc_nonshared.a"
  printf 'docs' >"$r/usr/share/doc/omarchy-wsl/README.md"
  chmod 1777 "$r/tmp" "$r/var/tmp"
}

header "leak & integrity audit"
AUDIT="$ROOT_DIR/tests/audit-rootfs-leaks.sh"
clean="$T/clean"
make_clean_rootfs "$clean"
check "clean synthetic rootfs passes" bash -c "bash '$AUDIT' '$clean' >/dev/null 2>&1"
check "missing rootfs fails closed" bash -c "! bash '$AUDIT' '$T/does-not-exist' >/dev/null 2>&1"
mkdir -p "$T/empty"
check "empty rootfs fails closed" bash -c "! bash '$AUDIT' '$T/empty' >/dev/null 2>&1"

leak_case() { # leak_case <description> <setup command run inside a fresh copy>
  local desc="$1" setup="$2" r="$T/leak-$TESTS_RUN"
  rm -rf "$r"
  cp -a "$clean" "$r"
  (cd "$r" && eval "$setup")
  check "audit catches: $desc" bash -c "! bash '$AUDIT' '$r' >/dev/null 2>&1"
}
leak_case "GitHub CLI token under any home" 'mkdir -p home/bob/.config/gh && echo "oauth_token: x" >home/bob/.config/gh/hosts.yml'
leak_case ".netrc in /root" 'echo "machine x login y password z" >root/.netrc'
leak_case ".git-credentials" 'mkdir -p home/carol && echo "https://u:p@example.invalid" >home/carol/.git-credentials'
leak_case "kube config" 'mkdir -p root/.kube && echo x >root/.kube/config'
leak_case "SSH private key" 'mkdir -p root/.ssh && echo x >root/.ssh/id_ed25519'
leak_case "token pattern in /etc" "printf 'TOKEN=gh%s_%s\n' p 0123456789abcdefghijklmnopqrstuvwxyz0123 >etc/environment"
leak_case "shell history" 'echo ls >root/.bash_history'
leak_case "build user left behind" 'echo "omarchy-builder:x:990:990::/var/lib/omarchy-builder:/bin/bash" >>etc/passwd'
leak_case "regular user account shipped" 'echo "alice:x:1000:1000::/home/alice:/bin/bash" >>etc/passwd'
leak_case "non-empty machine-id" 'echo 0123456789abcdef >etc/machine-id'
leak_case "SSH host key" 'echo x >etc/ssh/ssh_host_ed25519_key'
leak_case "pacman keyring" 'mkdir -p etc/pacman.d/gnupg && echo x >etc/pacman.d/gnupg/trustdb.gpg'
leak_case "resolv.conf" 'echo "nameserver 10.0.0.1" >etc/resolv.conf'
leak_case "pacman package cache" 'echo x >var/cache/pacman/pkg/foo.pkg.tar.zst'
leak_case "sudoers drop-in" 'echo "x ALL=(ALL) NOPASSWD: ALL" >etc/sudoers.d/10-x'
leak_case "setuid lost on sudo" 'chmod 0755 usr/bin/sudo'
leak_case "sticky bit lost on /var/tmp" 'chmod 0755 var/tmp'
leak_case "libc_nonshared.a deleted" 'rm usr/lib/libc_nonshared.a'
leak_case "root password hash" "printf 'root:\$6\$salt\$hash:19000::::::\n' >etc/shadow"
check "AUDIT_EXTRA_PATTERNS deny-list catches private names" bash -c "
  r='$T/extra'; rm -rf \"\$r\"; cp -a '$clean' \"\$r\"; echo 'host internal-build-box' >\"\$r/etc/hosts\"
  ! AUDIT_EXTRA_PATTERNS='internal-build-box' bash '$AUDIT' \"\$r\" >/dev/null 2>&1"

header "sanitiser (scripts/strip-rootfs.sh, ROOT=<tree>)"
s="$T/strip"
make_clean_rootfs "$s"
mkdir -p "$s"/{home/dave/.config/gh,root/.ssh,usr/lib/gcc/aarch64-unknown-linux-gnu/14,usr/share/doc/bash,usr/share/doc/omarchy-wsl,usr/share/locale/de/LC_MESSAGES,usr/share/locale/en_GB,var/lib/systemd,var/lib/pacman/sync,etc/pacman.d/gnupg,var/log/journal/x}
echo token >"$s/home/dave/.config/gh/hosts.yml"
echo secret >"$s/home/dave/.netrc"
echo npm >"$s/home/dave/.npmrc"
echo key >"$s/root/.ssh/id_rsa"
echo ls >"$s/root/.bash_history"
echo a >"$s/usr/lib/gcc/aarch64-unknown-linux-gnu/14/libgcc.a"
echo doc >"$s/usr/share/doc/bash/README"
echo de >"$s/usr/share/locale/de/LC_MESSAGES/x.mo"
echo en >"$s/usr/share/locale/en_GB/x.mo"
echo seed >"$s/var/lib/systemd/random-seed"
echo db >"$s/var/lib/pacman/sync/core.db"
echo key >"$s/etc/ssh/ssh_host_ed25519_key"
echo trust >"$s/etc/pacman.d/gnupg/trustdb.gpg"
echo 0123 >"$s/etc/machine-id"
echo log >"$s/var/log/pacman.log"
echo old >"$s/tmp/leftover"
if ROOT="$s" bash "$ROOT_DIR/scripts/strip-rootfs.sh" >"$T/strip.log" 2>&1; then
  pass "strip-rootfs.sh runs against a mounted tree"
else
  fail "strip-rootfs.sh failed: $(tail -3 "$T/strip.log")"
fi
check "keeps libc_nonshared.a" test -f "$s/usr/lib/libc_nonshared.a"
check "keeps gcc/**/libgcc.a" test -f "$s/usr/lib/gcc/aarch64-unknown-linux-gnu/14/libgcc.a"
check "keeps /usr/share/doc/omarchy-wsl" test -f "$s/usr/share/doc/omarchy-wsl/README.md"
check "drops other package docs" test ! -e "$s/usr/share/doc/bash"
check "drops non-English locales, keeps en*" bash -c "[[ ! -e '$s/usr/share/locale/de' && -e '$s/usr/share/locale/en_GB/x.mo' ]]"
check "removes .config/gh from every home" test ! -e "$s/home/dave/.config/gh"
check "removes .netrc and .npmrc" bash -c "[[ ! -e '$s/home/dave/.netrc' && ! -e '$s/home/dave/.npmrc' ]]"
check "removes /root/.ssh and history" bash -c "[[ ! -e '$s/root/.ssh' && ! -e '$s/root/.bash_history' ]]"
check "empties /etc/machine-id (0 bytes, present)" bash -c "[[ -f '$s/etc/machine-id' && ! -s '$s/etc/machine-id' ]]"
check "removes SSH host keys, random seed, sync DBs, keyring" bash -c "[[ ! -e '$s/etc/ssh/ssh_host_ed25519_key' && ! -e '$s/var/lib/systemd/random-seed' && ! -e '$s/var/lib/pacman/sync/core.db' && ! -e '$s/etc/pacman.d/gnupg' ]]"
check "truncates logs, clears /tmp, keeps 1777" bash -c "[[ ! -s '$s/var/log/pacman.log' && ! -e '$s/tmp/leftover' && \$(stat -c %a '$s/tmp' 2>/dev/null || stat -f %Lp '$s/tmp') == 1777 ]]"
check "sanitised tree passes the audit" bash -c "bash '$AUDIT' '$s' >/dev/null 2>&1"

header "deterministic export (scripts/normalize-rootfs.sh)"
if [[ $(uname -s) != Linux || $EUID -ne 0 ]]; then
  skip "normalisation needs root on Linux (run inside the test container)"
elif ! tar --version 2>/dev/null | grep -q 'GNU tar'; then
  skip "GNU tar not available"
else
  src="$T/export-src"
  make_clean_rootfs "$src"
  mkdir -p "$src/usr/share/omarchy" "$src/opt/owned"
  printf 'ping' >"$src/usr/bin/ping"
  chmod 0755 "$src/usr/bin/ping"
  echo data >"$src/opt/owned/file"
  chown -R 1234:5678 "$src/opt/owned"
  for f in a c b; do echo "$f" >"$src/usr/share/omarchy/$f"; done
  touch "$src/.dockerenv"
  echo "nameserver 10.0.0.1" >"$src/etc/resolv.conf"
  echo builder >"$src/etc/hostname"
  echo 0123456789abcdef >"$src/etc/machine-id"
  mkdir -p "$src/dev" && : >"$src/dev/console"
  cap_ok=0
  if python3 -c 'import os,struct,sys; os.setxattr(sys.argv[1], "security.capability", struct.pack("<IIIII", 0x02000001, 1 << 13, 0, 0, 0))' "$src/usr/bin/ping" 2>/dev/null; then
    cap_ok=1
  fi
  (cd "$src" && tar --xattrs --xattrs-include='security.capability' --numeric-owner -cf "$T/export.tar" .)
  run_normalize() { # run_normalize <output> [seed]
    SOURCE_DATE_EPOCH=$EPOCH SEED_LEAK="${2:-0}" NORMALIZE_ROOTFS="$T/work-rootfs" \
      AUDIT_SCRIPT="$AUDIT" bash "$ROOT_DIR/scripts/normalize-rootfs.sh" "$T/export.tar" "$1"
  }
  if run_normalize "$T/one.wsl" >"$T/n1.log" 2>&1 && run_normalize "$T/two.wsl" >"$T/n2.log" 2>&1; then
    pass "normalisation succeeds twice"
    check "two runs are byte-identical (sha256)" bash -c "[[ \$(sha256sum <'$T/one.wsl') == \$(sha256sum <'$T/two.wsl') ]]"
    check "output is gzip without name or timestamp (gzip -n)" bash -c "[[ \$(od -An -tx1 -j4 -N4 '$T/one.wsl' | tr -d ' ') == 00000000 ]]"
    x="$T/extracted"
    mkdir -p "$x"
    tar -xzpf "$T/one.wsl" -C "$x" --numeric-owner --xattrs --xattrs-include='security.capability'
    check "setuid sudo survives (4755, uid 0)" bash -c "[[ \$(stat -c '%a %u' '$x/usr/bin/sudo') == '4755 0' ]]"
    check "sticky /tmp and /var/tmp survive (1777)" bash -c "[[ \$(stat -c %a '$x/tmp') == 1777 && \$(stat -c %a '$x/var/tmp') == 1777 ]]"
    check "numeric ownership survives (1234:5678)" bash -c "[[ \$(stat -c '%u:%g' '$x/opt/owned/file') == 1234:5678 ]]"
    if ((cap_ok)); then
      check "security.capability survives on ping" python3 -c 'import os,sys; os.getxattr(sys.argv[1], "security.capability")' "$x/usr/bin/ping"
    else
      skip "cannot set security.capability here (needs CAP_SETFCAP)"
    fi
    check "runtime files removed (.dockerenv, resolv.conf, hostname, /dev/*)" bash -c "[[ ! -e '$x/.dockerenv' && ! -e '$x/etc/resolv.conf' && ! -e '$x/etc/hostname' && ! -e '$x/dev/console' && -d '$x/dev' ]]"
    check "machine-id emptied" bash -c "[[ -f '$x/etc/machine-id' && ! -s '$x/etc/machine-id' ]]"
    check "every member mtime is SOURCE_DATE_EPOCH" bash -c "! TZ=UTC tar --full-time -tvzf '$T/one.wsl' | grep -v ' 2023-11-14 22:13:20 ' | grep -q ."
    check "members are sorted by name" bash -c "tar -tzf '$T/one.wsl' | grep '^usr/share/omarchy/' | LC_ALL=C sort -c"
    check "PAX headers carry no PID (exthdr.name=%d/PaxHeaders/%f)" bash -c "! gzip -dc '$T/one.wsl' | grep -aq 'PaxHeaders\.[0-9]'"
  else
    fail "normalisation failed: $(tail -5 "$T/n1.log" "$T/n2.log" 2>/dev/null | tr '\n' ' ')"
  fi
  rc=0
  run_normalize "$T/seeded.wsl" 1 >"$T/seed.log" 2>&1 || rc=$?
  check "seeded leak: audit fails closed with exit 3" test "$rc" -eq 3
  check "seeded leak: no artifact written" test ! -e "$T/seeded.wsl"
fi

echo
echo "Build Pipeline Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
((TESTS_FAILED == 0)) || exit 1
if ((TESTS_SKIPPED > 0)) && [[ ${OMW_STRICT:-0} == 1 ]]; then exit 1; fi
exit 0
