#!/bin/bash
# ==============================================================================
# Omarchy WSL: Adversarial Rootfs Leak & Vulnerability Test Suite
# ==============================================================================
# Audits a target directory or extracted rootfs against all known leak vectors.
# Exit code 0 = Pristine & Clean; Non-zero = Vulnerabilities Detected.
# ==============================================================================

set -euo pipefail

TARGET_ROOT="${1:-}"
if [[ -z "$TARGET_ROOT" || ! -d "$TARGET_ROOT" ]]; then
  echo "Usage: $0 <path-to-extracted-rootfs>" >&2
  exit 1
fi

FAILURES=0

assert_not_exists() {
  local path="$1"
  local desc="$2"
  if [[ -e "${TARGET_ROOT}/${path}" ]]; then
    echo "  [FAIL] Security Leak: Found $desc at '${path}'" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  [PASS] $desc absent"
  fi
}

assert_file_empty() {
  local path="$1"
  local desc="$2"
  if [[ ! -f "${TARGET_ROOT}/${path}" ]]; then
    echo "  [FAIL] Expected file '$path' does not exist" >&2
    FAILURES=$((FAILURES + 1))
  elif [[ -s "${TARGET_ROOT}/${path}" ]]; then
    echo "  [FAIL] $desc at '$path' is not empty ($(stat -c %s "${TARGET_ROOT}/${path}" 2>/dev/null || stat -f %z "${TARGET_ROOT}/${path}") bytes)" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  [PASS] $desc at '$path' is verified 0 bytes"
  fi
}

assert_no_regex_matches() {
  local file="$1"
  local pattern="$2"
  local desc="$3"
  if [[ -f "${TARGET_ROOT}/${file}" ]] && grep -E "$pattern" "${TARGET_ROOT}/${file}" >/dev/null 2>&1; then
    echo "  [FAIL] Security Leak: Found $desc in '$file'" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  [PASS] No $desc in '$file'"
  fi
}

echo "========================================================================"
echo " Running Adversarial Security & Leak Audit on: $TARGET_ROOT"
echo "========================================================================"

# 1. Host Secrets & Credentials
assert_not_exists "root/.ssh" "Root SSH directory"
assert_not_exists "home/aqua/.ssh" "User SSH directory"
assert_not_exists "root/.claude" "Root Claude credentials"
assert_not_exists "home/aqua/.claude" "User Claude credentials"
assert_not_exists "root/.aws" "Root AWS credentials"
assert_not_exists "root/.gitconfig" "Root git credentials/config"

# 2. Build-Time Users & Sudo Escalations
assert_no_regex_matches "etc/passwd" "^(builder|makepkg|aur):" "Ephemeral build users in /etc/passwd"
assert_no_regex_matches "etc/shadow" "^(builder|makepkg|aur):" "Ephemeral build users in /etc/shadow"
assert_not_exists "etc/sudoers.d/builder" "Build user sudoers configuration"
assert_not_exists "etc/sudoers.d/makepkg" "Makepkg sudoers configuration"

# 3. Non-Reproducible Machine Identity & Entropy
assert_file_empty "etc/machine-id" "/etc/machine-id (must be 0 bytes for WSL/systemd firstboot)"
assert_not_exists "var/lib/systemd/random-seed" "Non-reproducible systemd random seed"
assert_not_exists "var/lib/urandom/random-seed" "Legacy random seed"

# 4. Interactive History & State
HIST_COUNT=$(find "${TARGET_ROOT}" -name "*_history" -o -name ".lesshst" -o -name ".viminfo" 2>/dev/null | wc -l)
if (( HIST_COUNT > 0 )); then
  echo "  [FAIL] Found $HIST_COUNT shell history / interactive state files" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  [PASS] Zero shell history files detected"
fi

# 5. Pacman Package Caches & Sockets
PKG_CACHE_COUNT=$(find "${TARGET_ROOT}/var/cache/pacman/pkg" -type f 2>/dev/null | wc -l || echo 0)
if (( PKG_CACHE_COUNT > 0 )); then
  echo "  [FAIL] Pacman package cache contains $PKG_CACHE_COUNT cached archive files" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  [PASS] Pacman package cache is completely purged"
fi

assert_not_exists "var/lib/pacman/db.lck" "Pacman database lock file"

SOCKET_COUNT=$(find "${TARGET_ROOT}/etc/pacman.d/gnupg" -name "S.*" -o -name "*.lock" 2>/dev/null | wc -l || echo 0)
if (( SOCKET_COUNT > 0 )); then
  echo "  [FAIL] Found $SOCKET_COUNT stale GPG sockets/locks in /etc/pacman.d/gnupg" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  [PASS] Zero stale GPG sockets in /etc/pacman.d/gnupg"
fi

# 6. Host Mount / Kernel Bleed
assert_not_exists "usr/lib/wsl/drivers" "Windows host GPU driver mount bleed (/usr/lib/wsl/drivers)"
assert_not_exists "usr/lib/modules" "Unneeded kernel modules directory (/usr/lib/modules)"

echo "========================================================================"
if (( FAILURES == 0 )); then
  echo " RESULT: AUDIT PASSED (0 leaks detected, pristine rootfs)"
  exit 0
else
  echo " RESULT: AUDIT FAILED ($FAILURES vulnerabilities/leaks detected)" >&2
  exit 1
fi
