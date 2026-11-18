#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Build Governance Test Suite
# tests/test_build_governance.sh
# ==============================================================================
# omarchy-build (systemd-run argv, environment, exit codes, DrvFs refusal) and
# the shipped cgroup units (build.slice, user-.slice drop-in, oomd drop-in,
# login-shell defaults).
#
# Tiers:
#   default             recorder-stub systemd-run + `systemd-analyze verify` of
#                       every shipped unit and of every property name the
#                       script passes (needs systemd-analyze; no PID 1 needed).
#   OMW_REAL_SYSTEMD=1  additionally runs the real `systemd-run --user --scope`
#                       (run it as a user whose systemd user manager is up,
#                       e.g. inside a privileged container booted with systemd).
#                       Not selecting this tier is not a skip.
#
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

BUILD="$ROOT_DIR/bin/omarchy-build"
CG="$ROOT_DIR/wsl/cgroups"
T=$(mktemp -d "${TMPDIR:-/tmp}/omw-build.XXXXXX")
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() { if [[ -n "${OMW_TEST_KEEP:-}" ]]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi; }
trap cleanup EXIT

# Property names omarchy-build may pass to a transient scope. Cross-checked
# against systemd below; MemoryOOMGroup and OOMScoreAdjust must never appear.
SCOPE_PROPERTY_ALLOWLIST=(CPUWeight IOWeight MemoryHigh MemoryMax OOMPolicy TasksMax)

export OMARCHY_POWER_GOVERNOR=off
ORIG_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
unset XDG_RUNTIME_DIR
export HOME="$T/home"
mkdir -p "$HOME" "$T/fakebin" "$T/log"

# Recorder systemd-run: one argv element per line, plus the environment the
# scope would inherit; then runs the command after "--" like the real one.
cat >"$T/fakebin/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$T/log/systemd-run.argv"
env >"$T/log/systemd-run.env"
while [[ \$# -gt 0 && "\$1" != "--" ]]; do shift; done
shift
exec "\$@"
EOF
chmod +x "$T/fakebin/systemd-run"

# =============================================================================
header "1. Static checks"
check "omarchy-build passes bash -n" bash -n "$BUILD"
if command -v shellcheck >/dev/null; then
  check "shellcheck -x is clean (omarchy-build, cgroup profile)" \
    bash -c "cd '$ROOT_DIR' && shellcheck -x bin/omarchy-build wsl/cgroups/omarchy-cgroup-profile.sh"
else
  skip "shellcheck not installed"
fi
check "cgroup login profile is POSIX sh" sh -n "$CG/omarchy-cgroup-profile.sh"

# =============================================================================
header "2. Command-line contract"
out=$("$BUILD" --help 2>"$T/err"); rc=$?
check "--help exits 0" test "$rc" -eq 0
check "--help prints usage on stdout" grep -q '^Usage: omarchy-build' <<<"$out"
check "--help writes nothing to stderr" test ! -s "$T/err"
out=$("$BUILD" -h 2>/dev/null); rc=$?
check "-h exits 0" test "$rc" -eq 0
out=$("$BUILD" --frobnicate true 2>"$T/err"); rc=$?
check "Unknown option exits 2" test "$rc" -eq 2
check "Unknown option: error + usage on stderr, stdout empty" \
  bash -c "grep -q 'Unknown option: --frobnicate' '$T/err' && grep -q '^Usage:' '$T/err' && [[ -z \"\$1\" ]]" _ "$out"
"$BUILD" >/dev/null 2>&1; rc=$?
check "Missing command exits 2" test "$rc" -eq 2
"$BUILD" -j abc true >/dev/null 2>&1; rc=$?
check "Non-numeric -j exits 2" test "$rc" -eq 2
"$BUILD" -j 0 true >/dev/null 2>&1; rc=$?
check "-j 0 exits 2" test "$rc" -eq 2
"$BUILD" --slice 'evil;rm.slice' true >/dev/null 2>&1; rc=$?
check "Invalid slice name exits 2" test "$rc" -eq 2

# =============================================================================
header "3. systemd-run argv (recorder stub)"
rm -f "$T/log/"*
(cd "$T/home" && PATH="$T/fakebin:$PATH" OMARCHY_BUILD_FORCE_SYSTEMD=1 FOO_MARK=kept \
  "$BUILD" -j 3 bash -c 'echo "J=$CARGO_BUILD_JOBS M=$MAKEFLAGS C=$CMAKE_BUILD_PARALLEL_LEVEL F=$FOO_MARK"; exit 7') \
  >"$T/out" 2>&1; rc=$?
expected="--user
--scope
--quiet
--collect
--slice=build.slice
--description=omarchy-build: bash
--property=CPUWeight=20
--property=IOWeight=20
--property=OOMPolicy=kill
--
bash
-c
echo \"J=\$CARGO_BUILD_JOBS M=\$MAKEFLAGS C=\$CMAKE_BUILD_PARALLEL_LEVEL F=\$FOO_MARK\"; exit 7"
check "Exact argv: --user --scope --slice=build.slice + valid properties" \
  test "$(cat "$T/log/systemd-run.argv" 2>/dev/null)" = "$expected"
check "Wrapped command's exit status is returned (7)" test "$rc" -eq 7
check "-j reaches the build via the inherited environment" grep -qx 'J=3 M=-j3 C=3 F=kept' "$T/out"
check "Caller environment (PATH, custom vars) is inherited by the scope" \
  bash -c "grep -qx 'FOO_MARK=kept' '$T/log/systemd-run.env' && grep -q '^PATH=$T/fakebin:' '$T/log/systemd-run.env'"
check "No invalid MemoryOOMGroup / OOMScoreAdjust property is passed" \
  bash -c "! grep -Eq 'MemoryOOMGroup|OOMScoreAdjust' '$T/log/systemd-run.argv'"
bad=0
while IFS= read -r a; do
  [[ "$a" == --property=* ]] || continue
  name="${a#--property=}"; name="${name%%=*}"
  printf '%s\n' "${SCOPE_PROPERTY_ALLOWLIST[@]}" | grep -qx "$name" || { bad=1; echo "      not allowlisted: $name"; }
done <"$T/log/systemd-run.argv"
check "Every --property name is in the scope allowlist" test "$bad" -eq 0

out=$(PATH="$T/fakebin:$PATH" OMARCHY_BUILD_FORCE_SYSTEMD=1 "$BUILD" --dry-run -j 2 make all)
check "--dry-run prints jobs, engine and the exact command" \
  bash -c "grep -qx 'jobs=2' <<<\"\$1\" && grep -qx 'engine=systemd' <<<\"\$1\" && grep -q '^command=systemd-run --user --scope' <<<\"\$1\" && grep -q -- '-- make all' <<<\"\$1\"" _ "$out"
out=$(PATH="$T/fakebin:$PATH" OMARCHY_BUILD_FORCE_SYSTEMD=1 "$BUILD" --dry-run --slice heavy.slice true)
check "--slice selects the target slice" grep -q -- '--slice=heavy.slice' <<<"$out"
out=$(PATH="$T/fakebin:$PATH" OMARCHY_BUILD_FORCE_SYSTEMD=1 "$BUILD" --dry-run --no-cgroup true)
check "--no-cgroup selects the direct engine" grep -qx 'engine=direct' <<<"$out"

# =============================================================================
header "4. Property names cross-checked with systemd-analyze"
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$T/units"
  {
    echo "[Unit]"; echo "Description=property probe"
    echo "[Service]"; echo "ExecStart=/bin/true"
    grep '^--property=' "$T/log/systemd-run.argv" | sed 's/^--property=//'
  } >"$T/units/omw-prop-probe.service"
  va=$(cd "$T/units" && systemd-analyze verify omw-prop-probe.service 2>&1)
  check "systemd-analyze knows every passed property (no 'Unknown')" bash -c "! grep -qi unknown <<<\"\$1\"" _ "$va"
  printf '[Unit]\nDescription=x\n[Service]\nExecStart=/bin/true\nMemoryOOMGroup=yes\n' >"$T/units/omw-bad.service"
  va=$(cd "$T/units" && systemd-analyze verify omw-bad.service 2>&1)
  check "Harness self-check: systemd-analyze flags MemoryOOMGroup" grep -q "Unknown key name 'MemoryOOMGroup'" <<<"$va"
else
  skip "systemd-analyze not installed: property cross-check disabled"
fi

# =============================================================================
header "5. Shipped cgroup units"
check "No MemoryOOMGroup/OOMScoreAdjust anywhere in wsl/cgroups" \
  bash -c "! grep -REq '^[[:space:]]*(MemoryOOMGroup|OOMScoreAdjust)' '$CG'"
check "build.slice Documentation= points at chntllh-labs/omarchy-wsl" \
  grep -qx 'Documentation=https://github.com/chntllh-labs/omarchy-wsl' "$CG/build.slice"
check "build.slice uses ManagedOOMMemoryPressure=kill + a limit" \
  bash -c "grep -qx 'ManagedOOMMemoryPressure=kill' '$CG/build.slice' && grep -q '^ManagedOOMMemoryPressureLimit=[0-9]*%$' '$CG/build.slice'"
check "build.slice deprioritises CPU and I/O below the default weight" \
  bash -c "grep -qx 'CPUWeight=20' '$CG/build.slice' && grep -qx 'IOWeight=20' '$CG/build.slice'"
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$T/sys/user-1000.slice.d"
  cp "$CG/build.slice" "$T/sys/build.slice"
  printf '[Unit]\nDescription=User Slice of UID 1000\n' >"$T/sys/user-1000.slice"
  cp "$CG/10-interactive-protection.conf" "$T/sys/user-1000.slice.d/"
  va=$(cd "$T/sys" && systemd-analyze verify build.slice 2>&1)
  check "systemd-analyze verify build.slice: no unknown keys" bash -c "! grep -qi unknown <<<\"\$1\"" _ "$va"
  va=$(cd "$T/sys" && systemd-analyze verify user-1000.slice 2>&1)
  check "systemd-analyze verify user-.slice drop-in: no unknown keys" bash -c "! grep -qi unknown <<<\"\$1\"" _ "$va"
  printf '[Slice]\nOOMScoreAdjust=-200\n' >"$T/sys/user-1000.slice.d/99-bad.conf"
  va=$(cd "$T/sys" && systemd-analyze verify user-1000.slice 2>&1)
  check "Harness self-check: drop-ins are really verified (bad key flagged)" grep -q "Unknown key name 'OOMScoreAdjust'" <<<"$va"
else
  skip "systemd-analyze not installed: unit verification disabled"
fi
bad=0
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*(#|$|\[OOM\]) ]] && continue
  case "${line%%=*}" in
    SwapUsedLimit|DefaultMemoryPressureLimit|DefaultMemoryPressureDurationSec) ;;
    *) bad=1; echo "      unknown oomd.conf key: ${line%%=*}" ;;
  esac
done <"$CG/10-omarchy-oomd.conf"
check "oomd drop-in uses only oomd.conf(5) keys" test "$bad" -eq 0

# Login-shell defaults (installed as /etc/profile.d/60-omarchy-cgroup-governance.sh)
out=$(env -i PATH=/usr/bin:/bin sh -c ". '$CG/omarchy-cgroup-profile.sh'; echo \"\$CARGO_BUILD_JOBS|\$MAKEFLAGS|\$CMAKE_BUILD_PARALLEL_LEVEL\"")
check "Profile exports CARGO_BUILD_JOBS / MAKEFLAGS / CMAKE level" bash -c "[[ \"\$1\" =~ ^([0-9]+)\\|-j([0-9]+)\\|([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 1 ))" _ "$out"
out=$(env -i PATH=/usr/bin:/bin MAKEFLAGS=-k CARGO_BUILD_JOBS=1 CMAKE_BUILD_PARALLEL_LEVEL=1 sh -c ". '$CG/omarchy-cgroup-profile.sh'; echo \"\$CARGO_BUILD_JOBS|\$MAKEFLAGS\"")
check "Profile never overrides user-set values" test "$out" = "1|-k"
check "Profile header names its install path" grep -q '/etc/profile.d/60-omarchy-cgroup-governance.sh' "$CG/omarchy-cgroup-profile.sh"

# =============================================================================
header "6. DrvFs refusal (9p and virtiofs)"
mkdir -p "$T/mnt/c/proj" "$T/mnt/d/proj"
cat >"$T/mountinfo" <<EOF
22 1 8:1 / / rw - ext4 /dev/sdc rw
80 22 0:50 / $T/mnt/c rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\
81 22 0:51 / $T/mnt/d rw,noatime - virtiofs D:\\134 rw
EOF
(cd "$T/mnt/c/proj" && OMW_MOUNTINFO="$T/mountinfo" "$BUILD" --no-cgroup true) >/dev/null 2>"$T/err"; rc=$?
check "Build on a 9p DrvFs drive is refused (exit 3)" test "$rc" -eq 3
check "Refusal explains the fix" grep -q 'allow-drvfs' "$T/err"
(cd "$T/mnt/d/proj" && OMW_MOUNTINFO="$T/mountinfo" "$BUILD" --no-cgroup true) >/dev/null 2>&1; rc=$?
check "Build on a virtiofs Windows drive is refused too (no bypass)" test "$rc" -eq 3
(cd "$T/mnt/c/proj" && OMW_MOUNTINFO="$T/mountinfo" "$BUILD" --allow-drvfs --no-cgroup true) >/dev/null 2>&1; rc=$?
check "--allow-drvfs permits it" test "$rc" -eq 0
(cd "$T/mnt/c/proj" && OMW_MOUNTINFO="$T/mountinfo" OMARCHY_DRVFS_GUARD=warn "$BUILD" --no-cgroup true) >/dev/null 2>&1; rc=$?
check "OMARCHY_DRVFS_GUARD=warn only warns" test "$rc" -eq 0
(cd "$T/home" && OMW_MOUNTINFO="$T/mountinfo" "$BUILD" --no-cgroup true) >/dev/null 2>&1; rc=$?
check "ext4 builds are untouched" test "$rc" -eq 0

# =============================================================================
header "7. Direct engine (no user manager)"
out=$(cd "$T/home" && "$BUILD" --no-cgroup -j 2 sh -c 'echo "$CARGO_BUILD_JOBS $MAKEFLAGS $(cat /proc/self/oom_score_adj)"; exit 4'); rc=$?
check "Direct engine returns the command's exit status" test "$rc" -eq 4
check "Direct engine exports the job variables" bash -c "[[ \"\$1\" == '2 -j2 '* ]]" _ "$out"
check "Build oom_score_adj is raised to at least 500" bash -c "(( \${1##* } >= 500 ))" _ "$out"

# =============================================================================
if [[ "${OMW_REAL_SYSTEMD:-0}" == 1 ]]; then
  header "8. Real systemd-run --user --scope (OMW_REAL_SYSTEMD=1)"
  export XDG_RUNTIME_DIR="${ORIG_XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if systemctl --user is-active basic.target >/dev/null 2>&1; then
    out=$(cd "$T/home" && FOO_MARK=kept "$BUILD" -j 3 bash -c '
      scope=$(sed -n "s|^0::.*/||p" /proc/self/cgroup)
      echo "cg=$(cat /proc/self/cgroup)"
      echo "env=$CARGO_BUILD_JOBS|$MAKEFLAGS|$CMAKE_BUILD_PARALLEL_LEVEL|$FOO_MARK"
      echo "oom=$(cat /proc/self/oom_score_adj)"
      echo "policy=$(systemctl --user show "$scope" -p OOMPolicy --value)"
      echo "cpuw=$(systemctl --user show "$scope" -p CPUWeight --value)"
      exit 9' 2>&1); rc=$?
    check "Real run: command lands in build.slice of the user manager" grep -q '^cg=0::/.*user@[0-9]*\.service/build\.slice/.*\.scope$' <<<"$out"
    check "Real run: exit status 9 is returned" test "$rc" -eq 9
    check "Real run: -j variables and caller env reach the build" grep -qx 'env=3|-j3|3|kept' <<<"$out"
    check "Real run: oom_score_adj 500" grep -qx 'oom=500' <<<"$out"
    check "Real run: scope has OOMPolicy=kill" grep -qx 'policy=kill' <<<"$out"
    check "Real run: scope has CPUWeight=20" grep -qx 'cpuw=20' <<<"$out"
  else
    fail "OMW_REAL_SYSTEMD=1 but no systemd user manager is reachable (systemctl --user)"
  fi
fi

echo
echo "Build Governance Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-0}" == 1 ]]; then exit 1; fi
exit 0
