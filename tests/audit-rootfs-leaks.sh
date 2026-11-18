#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: root filesystem leak and integrity audit
# ==============================================================================
#   tests/audit-rootfs-leaks.sh <extracted-rootfs> [--no-integrity]
#
# Exit 0 only when the tree is clean. Fails closed: a missing or empty rootfs
# is a failure, not a pass. scripts/build-reproducible-rootfs.sh runs it as
# root inside the normalisation container, on the exact tree it archives, and
# proves it fails on a seeded leak (--seed-leak).
#
# Leak checks: credentials and keys under /root and every /home/*, token
# patterns in /root, /home and /etc, shell history, build users and their sudo
# rules, per-machine identity (machine-id, SSH host keys, random seed, pacman
# keyring), package caches, container-runtime files.
# Integrity checks (skip with --no-integrity for synthetic trees): setuid sudo,
# sticky /tmp and /var/tmp, libc_nonshared.a, root locked without a hash.
#
# AUDIT_EXTRA_PATTERNS (newline-separated extended regexes) adds deny patterns
# at run time, e.g. private host names that must never ship but must not be
# written into this public repository either.
# ==============================================================================

set -uo pipefail

ROOT="${1:-}"
INTEGRITY=1
[[ ${2:-} == --no-integrity ]] && INTEGRITY=0

if [[ -z $ROOT || ! -d $ROOT ]] || [[ -z $(ls -A "$ROOT" 2>/dev/null) ]]; then
  echo "usage: $0 <extracted-rootfs> [--no-integrity]  (rootfs missing or empty)" >&2
  exit 2
fi
ROOT="${ROOT%/}"

FAILURES=0
CHECKS=0
pass() {
  CHECKS=$((CHECKS + 1))
  echo "  [PASS] $*"
}
fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  echo "  [FAIL] $*" >&2
}

absent() {
  local path="$1" desc="$2"
  if [[ -e $ROOT/$path || -L $ROOT/$path ]]; then fail "$desc present: /$path"; else pass "$desc absent"; fi
}

# Every user home plus /root.
homes=("$ROOT/root")
for h in "$ROOT"/home/*; do [[ -d $h ]] && homes+=("$h"); done

echo "== Leak & integrity audit: $ROOT"

echo "-- credentials and keys"
found=$(find "${homes[@]}" -xdev \( \
  -path '*/.ssh' -o -path '*/.gnupg' -o -path '*/.aws' -o -path '*/.azure' -o -path '*/.kube' -o \
  -path '*/.docker' -o -path '*/.claude' -o -path '*/.config/gh' -o -path '*/.config/gcloud' -o \
  -path '*/.password-store' -o -path '*/.local/share/keyrings' -o \
  -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' -o -name '.git-credentials' -o -name '.claude.json' -o \
  -name '.vault-token' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' -o -name '*.pem' -o -name '*.key' \
  \) -print 2>/dev/null)
if [[ -n $found ]]; then fail "credential material: $(tr '\n' ' ' <<<"${found//$ROOT/}")"; else pass "no credential files or directories under /root or /home/*"; fi

echo "-- token and private-key patterns"
token_re='(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|tskey-[A-Za-z0-9-]{10,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----)'
hits=$(grep -rIlE --exclude-dir=ssl --exclude-dir=ca-certificates --exclude-dir=pki "$token_re" "${homes[@]}" "$ROOT/etc" 2>/dev/null | head -n 20)
if [[ -n $hits ]]; then fail "secret-like content in: $(tr '\n' ' ' <<<"${hits//$ROOT/}")"; else pass "no token or private-key patterns in /root, /home, /etc"; fi
if [[ -n ${AUDIT_EXTRA_PATTERNS:-} ]]; then
  extra=$(grep -rIlE -f <(printf '%s\n' "$AUDIT_EXTRA_PATTERNS") "${homes[@]}" "$ROOT/etc" "$ROOT/usr/share/omarchy-wsl" "$ROOT/usr/lib/omarchy-wsl" 2>/dev/null | head -n 20)
  if [[ -n $extra ]]; then fail "deny-listed content in: $(tr '\n' ' ' <<<"${extra//$ROOT/}")"; else pass "no deny-listed patterns (AUDIT_EXTRA_PATTERNS)"; fi
fi

echo "-- history and interactive state"
hist=$(find "$ROOT" -xdev \( -path "$ROOT/proc" -o -path "$ROOT/sys" -o -path "$ROOT/dev" \) -prune -o \
  -type f \( -name '.*_history' -o -name '.lesshst' -o -name '.viminfo' -o -name '.wget-hsts' \) -print 2>/dev/null)
if [[ -n $hist ]]; then fail "history files: $(tr '\n' ' ' <<<"${hist//$ROOT/}")"; else pass "no shell history or editor state"; fi

echo "-- build users and sudo rules"
if grep -qE '^(omarchy-builder|builder|makepkg|aur|alarm):' "$ROOT/etc/passwd" "$ROOT/etc/shadow" 2>/dev/null; then
  fail "build or stock users remain in /etc/passwd or /etc/shadow"
else
  pass "no build users (omarchy-builder, builder, makepkg, aur) and no 'alarm'"
fi
if [[ -n $(awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' "$ROOT/etc/passwd" 2>/dev/null) ]]; then
  fail "regular user accounts ship in the image: $(awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' "$ROOT/etc/passwd" | tr '\n' ' ')"
else
  pass "no regular user accounts (the OOBE creates uid 1000)"
fi
extra_sudo=$(find "$ROOT/etc/sudoers.d" -type f 2>/dev/null)
if [[ -n $extra_sudo ]]; then fail "sudoers drop-ins ship: $(tr '\n' ' ' <<<"${extra_sudo//$ROOT/}")"; else pass "no sudoers drop-ins"; fi

echo "-- per-machine identity"
if [[ ! -f $ROOT/etc/machine-id ]]; then
  fail "/etc/machine-id missing (must exist and be empty)"
elif [[ -s $ROOT/etc/machine-id ]]; then
  fail "/etc/machine-id is not empty"
else
  pass "/etc/machine-id is 0 bytes"
fi
absent etc/pacman.d/gnupg "pacman keyring (generated per install on first boot)"
absent var/lib/systemd/random-seed "systemd random seed"
absent var/lib/urandom/random-seed "legacy random seed"
absent etc/resolv.conf "/etc/resolv.conf (WSL generates it)"
absent etc/hostname "/etc/hostname (WSL sets it)"
absent .dockerenv "container runtime marker"
absent etc/omarchy-user.conf "provisioned-user configuration"
absent var/lib/omarchy/oobe_completed "OOBE completion sentinel"
hostkeys=$(find "$ROOT/etc/ssh" -maxdepth 1 -name 'ssh_host_*' 2>/dev/null)
if [[ -n $hostkeys ]]; then fail "SSH host keys ship (every install must generate its own)"; else pass "no SSH host keys"; fi

echo "-- caches and locks"
cache=$(find "$ROOT/var/cache/pacman/pkg" -type f 2>/dev/null | wc -l)
if ((cache > 0)); then fail "pacman cache holds $cache files"; else pass "pacman package cache empty"; fi
absent var/lib/pacman/db.lck "pacman database lock"
absent usr/lib/wsl/drivers "host GPU driver mount contents"
mods=$(find "$ROOT/usr/lib/modules" -mindepth 1 2>/dev/null | head -n 1)
if [[ -n $mods ]]; then fail "kernel modules ship (WSL provides its own)"; else pass "no kernel modules"; fi

if ((INTEGRITY)); then
  echo "-- integrity"
  mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
  expect() { # expect <description> <command...>
    local desc="$1"
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
  }
  expect "/usr/bin/sudo is setuid root (4755)" test "$(mode_of "$ROOT/usr/bin/sudo")" = 4755
  expect "/tmp is 1777" test "$(mode_of "$ROOT/tmp")" = 1777
  expect "/var/tmp is 1777" test "$(mode_of "$ROOT/var/tmp")" = 1777
  expect "libc_nonshared.a present (gcc can link)" test -f "$ROOT/usr/lib/libc_nonshared.a"
  root_hash=$(awk -F: '$1 == "root" { print $2 }' "$ROOT/etc/shadow" 2>/dev/null)
  expect "root is locked without a password hash" bash -c '[[ $1 == "!*" || $1 == "*" || $1 == "!" ]]' _ "$root_hash"
  expect "/usr/share/doc/omarchy-wsl ships" test -d "$ROOT/usr/share/doc/omarchy-wsl"
fi

echo "== $((CHECKS - FAILURES))/$CHECKS checks passed, $FAILURES failed"
((FAILURES == 0))
