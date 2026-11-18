#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Migration Gate Test Suite
# tests/test_migration_gate.sh
# ==============================================================================
# Runs lib/omarchy-wsl-migration-gate against fixture upstream migrations in a
# sandboxed HOME, with recorder stubs for sudo / sysctl / systemctl. Covers the
# pending counter under set -e, the /usr/share/omarchy layout, per-user state,
# private shims (nothing created under /usr), failure handling, dry-run and the
# root -> user hand-off.
#
# When run as root inside a container that has a `tester` account (the CI
# image), the hand-off is exercised for real with runuser; elsewhere that tier
# is simply not selected (no skip is reported).
# OMW_STRICT=1 turns every skip into a failing exit status.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_OK=$'\e[32m' C_BAD=$'\e[31m' C_SKIP=$'\e[33m' C_HDR=$'\e[1;36m' C_END=$'\e[0m'
else
  C_OK="" C_BAD="" C_SKIP="" C_HDR="" C_END=""
fi
pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  %s[PASS]%s %s\n' "$C_OK" "$C_END" "$*"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  %s[FAIL]%s %s\n' "$C_BAD" "$C_END" "$*"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  %s[SKIP]%s %s\n' "$C_SKIP" "$C_END" "$*"; }
header() { printf '\n%s>>> %s%s\n' "$C_HDR" "$*" "$C_END"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

GATE="$ROOT_DIR/lib/omarchy-wsl-migration-gate"
T=$(mktemp -d "${TMPDIR:-/tmp}/omw-gate.XXXXXX")
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() { if [[ -n "${OMW_TEST_KEEP:-}" ]]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi; }
trap cleanup EXIT
chmod 0755 "$T"

OP="$T/omarchy"          # fixture OMARCHY_PATH (upstream tree)
H="$T/home"              # sandboxed HOME
LOG="$T/log"
STUBS="$T/stubs"
GR="$T/root"             # OMARCHY_GATE_ROOT
mkdir -p "$OP/migrations" "$H/.config/app" "$LOG" "$STUBS" "$GR/etc/sysctl.d" "$GR/etc/systemd/system" "$GR/usr/lib/systemd/user"
echo 'export PS1=x' >"$H/.bashrc"
echo 'user=1' >"$H/.config/app/settings"
cp "$ROOT_DIR/wsl/sysctl.d/99-zz-omarchy-wsl-stability.conf" "$GR/etc/sysctl.d/"
cp "$ROOT_DIR/wsl/cgroups/build.slice" "$GR/etc/systemd/system/"
cp "$ROOT_DIR/wsl/cgroups/build.slice" "$GR/usr/lib/systemd/user/"

cat >"$OP/migrations/1001.sh" <<'EOF'
echo "ran-1001" >>"$HOME/ran.log"
EOF
cat >"$OP/migrations/1002.sh" <<'EOF'
echo "ran-1002" >>"$HOME/ran.log"
echo "$PATH" >"$HOME/migration-path"
systemctl enable --now sddm.service >"$HOME/sddm.out"
limine-update >"$HOME/limine.out"
EOF

# Recorder stubs: sysctl, systemctl (is-enabled answers per unit), sudo -n.
cat >"$STUBS/sysctl" <<EOF
#!/bin/sh
echo "sysctl \$*" >>"$LOG/root.calls"
EOF
cat >"$STUBS/systemctl" <<EOF
#!/bin/sh
if [ "\$1" = is-enabled ]; then
  case "\$2" in systemd-resolved.service|tmp.mount) echo masked ;; *) echo enabled ;; esac
  exit 0
fi
echo "systemctl \$*" >>"$LOG/root.calls"
EOF
cat >"$STUBS/sudo" <<EOF
#!/bin/sh
[ "\$1" = -n ] && shift
[ "\$1" = true ] && exit 0
exec "\$@"
EOF
chmod +x "$STUBS"/*
mkdir -p "$T/nosudo"; ln -sf "$STUBS/sysctl" "$T/nosudo/sysctl"; ln -sf "$STUBS/systemctl" "$T/nosudo/systemctl"

gate() {  # gate <stub-dir> [args...]: run the gate in the sandbox
  local stubdir="$1"; shift
  env HOME="$H" OMARCHY_PATH="$OP" OMARCHY_GATE_ROOT="$GR" NO_COLOR=1 PATH="$stubdir:/usr/bin:/bin" \
    bash "$GATE" "$@"
}

# =============================================================================
header "1. Static checks"
check "bash -n" bash -n "$GATE"
if command -v shellcheck >/dev/null; then
  check "shellcheck -x clean (gate, this suite)" bash -c "cd '$ROOT_DIR' && shellcheck -x lib/omarchy-wsl-migration-gate tests/test_migration_gate.sh"
else
  skip "shellcheck not installed"
fi
check "Upstream tree defaults to /usr/share/omarchy" grep -q 'OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"' "$GATE"
check "Per-user state defaults to ~/.local/state/omarchy/migrations" grep -q 'OMARCHY_MIGRATIONS_STATE_PATH:-$HOME/.local/state/omarchy/migrations' "$GATE"
check "No ((x++)) arithmetic that aborts under set -e" bash -c "! grep -Eq '\\(\\([a-z_]+\\+\\+\\)\\)' '$GATE'"
check "Never creates the shim directory under /usr" bash -c "! grep -q 'mkdir.*/usr' '$GATE'"

# =============================================================================
header "2. Running pending migrations (unprivileged, no sudo)"
if (( EUID == 0 )); then
  # As root the gate hands migrations to a user; run the unprivileged phase
  # directly so this section tests the same code path for everyone.
  out=$(env HOME="$H" OMARCHY_PATH="$OP" OMARCHY_GATE_ROOT="$GR" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" \
        bash "$GATE" --user-phase 2>&1); rc=$?
else
  out=$(gate "$T/nosudo" 2>&1); rc=$?
fi
check "Two pending migrations both run (counter does not abort set -e)" \
  bash -c "[[ $rc -eq 0 ]] && [[ \"\$(cat '$H/ran.log' 2>/dev/null)\" == \$'ran-1001\\nran-1002' ]]"
check "Applied migrations recorded in ~/.local/state/omarchy/migrations" \
  bash -c "[[ -f '$H/.local/state/omarchy/migrations/1001.sh' && -f '$H/.local/state/omarchy/migrations/1002.sh' ]]"
check "Bare-metal systemctl operation intercepted by the shim" grep -q 'WSL-SHIM' "$H/sddm.out"
check "Bootloader tool (limine-update) is a logged no-op" grep -q 'WSL-SHIM' "$H/limine.out"
shimdir=$(cut -d: -f1 "$H/migration-path" 2>/dev/null)
check "Shims live in a private per-run directory, removed afterwards" \
  bash -c "[[ -n '$shimdir' && '$shimdir' != /usr/* && ! -e '$shimdir' ]]"
check "Nothing was created under /usr/lib/omarchy-wsl/shims" test ! -e /usr/lib/omarchy-wsl/shims
check "User configuration snapshot taken before migrating" \
  bash -c "compgen -G '$H/.local/state/omarchy/migration-backups/*/.config/app/settings' >/dev/null"
check "Summary reports the applied count" grep -q 'Applied 2 migration(s)' <<<"$out"

# =============================================================================
header "3. Idempotence, skipped/ markers, failures, dry-run"
rm -f "$H/ran.log"
rm -rf "$H/.local/state/omarchy/migration-backups"
out=$(env HOME="$H" OMARCHY_PATH="$OP" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" bash "$GATE" --user-phase 2>&1); rc=$?
check "Nothing pending: nothing runs" bash -c "[[ $rc -eq 0 && ! -e '$H/ran.log' ]] && grep -q 'up to date' <<<\"\$1\"" _ "$out"
check "Nothing pending: no snapshot is taken" test ! -e "$H/.local/state/omarchy/migration-backups"
printf 'echo ran-1003 >>"$HOME/ran.log"\n' >"$OP/migrations/1003.sh"
mkdir -p "$H/.local/state/omarchy/migrations/skipped"
: >"$H/.local/state/omarchy/migrations/skipped/1003.sh"
env HOME="$H" OMARCHY_PATH="$OP" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" bash "$GATE" --user-phase >/dev/null 2>&1
check "Upstream skipped/<name> markers are honoured" test ! -e "$H/ran.log"
printf 'echo ran-1004 >>"$HOME/ran.log"\nfalse\necho after-false >>"$HOME/ran.log"\n' >"$OP/migrations/1004.sh"
printf 'echo ran-1005 >>"$HOME/ran.log"\n' >"$OP/migrations/1005.sh"
out=$(env HOME="$H" OMARCHY_PATH="$OP" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" bash "$GATE" --user-phase 2>&1); rc=$?
check "Failing migration: non-zero exit" test "$rc" -ne 0
check "Failing migration runs under bash -e and stops at the error" bash -c "[[ \"\$(cat '$H/ran.log')\" == ran-1004 ]]"
check "Failed migration is not marked applied; later ones did not run" \
  bash -c "[[ ! -e '$H/.local/state/omarchy/migrations/1004.sh' && ! -e '$H/.local/state/omarchy/migrations/1005.sh' ]]"
check "Failure points at the snapshot" grep -q 'snapshot' <<<"$out"
rm -f "$OP/migrations/1004.sh" "$H/ran.log"
rm -rf "$H/.local/state/omarchy/migration-backups"
out=$(env HOME="$H" OMARCHY_PATH="$OP" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" bash "$GATE" --user-phase --dry-run 2>&1)
check "--dry-run lists pending migrations and runs nothing" \
  bash -c "grep -qx 'pending: 1005.sh' <<<\"\$1\" && [[ ! -e '$H/ran.log' && ! -e '$H/.local/state/omarchy/migration-backups' ]]" _ "$out"
out=$(env -u OMARCHY_PATH HOME="$H" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" bash "$GATE" --user-phase --dry-run 2>&1)
check "Default migrations directory is /usr/share/omarchy/migrations" \
  bash -c "[[ -d /usr/share/omarchy/migrations ]] || grep -q '/usr/share/omarchy/migrations' <<<\"\$1\"" _ "$out"

# =============================================================================
header "4. Stability lockdown"
rm -f "$LOG/root.calls"
if (( EUID == 0 )); then
  out=$(gate "$STUBS" --user omw-no-such-user 2>&1); rc=$?
else
  out=$(gate "$STUBS" 2>&1); rc=$?
fi
check "Stability sysctl re-applied from /etc/sysctl.d" \
  grep -qx "sysctl -q -p $GR/etc/sysctl.d/99-zz-omarchy-wsl-stability.conf" "$LOG/root.calls"
check "Units that are not masked get masked; masked ones are left alone" \
  bash -c "grep -qx 'systemctl mask systemd-networkd.service' '$LOG/root.calls' && ! grep -q 'mask systemd-resolved.service' '$LOG/root.calls'"
check "Shipped cgroup units are only checked, never copied over admin edits" \
  bash -c "! grep -q 'build.slice' '$LOG/root.calls' && ! grep -q 'missing' <<<\"\$1\"" _ "$out"
rm -f "$LOG/root.calls"
if (( EUID != 0 )); then
  out=$(gate "$T/nosudo" 2>&1); rc=$?
  check "Without root or sudo: privileged steps are skipped with a warning, never prompted" \
    bash -c "[[ $rc -eq 0 && ! -s '$LOG/root.calls' ]] && grep -q 'Skipped (needs root)' <<<\"\$1\"" _ "$out"
fi
rm -f "$GR/etc/sysctl.d/99-zz-omarchy-wsl-stability.conf"
if (( EUID == 0 )); then out=$(gate "$STUBS" --user omw-no-such-user 2>&1); else out=$(gate "$STUBS" 2>&1); fi
check "Missing stability sysctl is reported" grep -q '99-zz-omarchy-wsl-stability.conf is not installed' <<<"$out"

# =============================================================================
header "5. Root never runs user migrations against /root"
printf 'echo ran-1006 >>"$HOME/ran.log"\n' >"$OP/migrations/1006.sh"
if (( EUID == 0 )); then
  rm -f "$H/ran.log"
  out=$(env HOME=/root OMARCHY_PATH="$OP" OMARCHY_GATE_ROOT="$GR" NO_COLOR=1 PATH="$STUBS:/usr/bin:/bin" \
        bash "$GATE" --user omw-no-such-user 2>&1)
  check "Root without a resolvable target user runs no migration" \
    bash -c "[[ ! -e /root/ran.log ]] && grep -q 'not run as root' <<<\"\$1\"" _ "$out"
  if id tester >/dev/null 2>&1 && [[ -e /run/.containerenv || -e /.dockerenv ]]; then
    th=$(getent passwd tester | cut -d: -f6)
    chmod -R a+rX "$OP"
    rm -f "$th/ran.log"
    out=$(env OMARCHY_PATH="$OP" OMARCHY_GATE_ROOT="$GR" NO_COLOR=1 PATH="$STUBS:/usr/bin:/bin" \
          bash "$GATE" --user tester --no-lockdown 2>&1); rc=$?
    [[ $rc -eq 0 ]] || printf '%s\n' "$out" | sed 's/^/      /'
    check "Root hands migrations to --user (HOME and state of that user)" \
      bash -c "[[ $rc -eq 0 ]] && grep -q ran-1006 '$th/ran.log' && [[ -f '$th/.local/state/omarchy/migrations/1006.sh' ]] && [[ \$(stat -c %U '$th/ran.log') == tester ]]"
    rm -rf "$th/ran.log" "$th/.local/state/omarchy" "$th/migration-path" "$th/sddm.out" "$th/limine.out" "$th/.bashrc.local"
  fi
else
  out=$(env HOME="$H" OMARCHY_PATH="$OP" NO_COLOR=1 PATH="$T/nosudo:/usr/bin:/bin" bash "$GATE" --user root 2>&1); rc=$?
  check "--user for another account needs root (exit 2)" test "$rc" -eq 2
fi

echo
echo "Migration Gate Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-0}" == 1 ]]; then exit 1; fi
exit 0
