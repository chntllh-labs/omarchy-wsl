#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: omarchy-rename-owner Adversarial Suite
# /tests/test_rename_owner.sh
# ==============================================================================
# T1 (always, no root needed): the real bin/omarchy-rename-owner against a
#    sandbox provisioned by the real wsl/oobe.sh. A fake passwd/group/shadow
#    lives under OMARCHY_PASSWD_ROOT; usermod, groupmod, useradd, groupadd,
#    passwd, runuser, chown, loginctl, systemctl, pgrep and git are recorder
#    stubs on PATH, and the real visudo validates every sudoers file. Covers
#    the ordered plan, --dry-run (sandbox byte-identical), idempotency, the
#    name table, rollback after a fault at every step, an incomplete rollback
#    followed by a resumed run, SIGTERM/SIGINT, sessions and the exit codes.
# T2 (root inside a throwaway container): the same flow with real useradd,
#    usermod, groupmod, visudo, su, sudo and git worktrees.
#
#   OMW_STRICT=1      a skipped check counts as a failure; T2 must run
#   OMW_REAL_ROOT=0   explicitly disable T2 (not counted)
#   OMW_TEST_KEEP=1   keep the sandbox for inspection
# ==============================================================================
# Helpers are reached through `check`, `trap` and bash -c (indirect calls).
# shellcheck disable=SC2317

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="$ROOT_DIR/bin/omarchy-rename-owner"
OOBE="$ROOT_DIR/wsl/oobe.sh"
ACCOUNT_LIB="$ROOT_DIR/lib/omarchy-wsl-account.sh"
COMMON_LIB="$ROOT_DIR/lib/omarchy-wsl-common.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\e[32m' C_R=$'\e[31m' C_Y=$'\e[33m' C_B=$'\e[1m\e[36m' C_0=$'\e[0m'
else
  C_G="" C_R="" C_Y="" C_B="" C_0=""
fi
pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_0" "$*"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  %s[SKIP]%s %s\n' "$C_Y" "$C_0" "$*"; }
header() { printf '\n%s>>> TEST SUITE: %s%s\n' "$C_B" "$*" "$C_0"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

unset CI DEBIAN_FRONTEND SSH_CONNECTION SSH_TTY OMARCHY_USER WSLENV USERNAME OMARCHY_WSL_LIB_DIR WSL_DISTRO_NAME

T="$(mktemp -d "${TMPDIR:-/tmp}/omw-rename.XXXXXX")"
BG_PIDS=()
cleanup() {
  local p
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  [[ "$(type -t t2_restore)" == "function" ]] && t2_restore
  if [[ -n "${OMW_TEST_KEEP:-}" ]]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

LOG="$T/log"
FAKEBIN="$T/fakebin"
SB="$T/root"
mkdir -p "$LOG" "$FAKEBIN"

# -----------------------------------------------------------------------------
# Recorder stubs ("<cmd> <argv...>" appended to $LOG/calls)
# -----------------------------------------------------------------------------
write_stub() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "%s $*" >>"%s/calls"\n' "$name" "$LOG"
    printf '%s\n' "$body"
  } >"$FAKEBIN/$name"
  chmod +x "$FAKEBIN/$name"
}
E='E="$OMARCHY_PASSWD_ROOT/etc"'

write_stub useradd "$E"'
m=0 uid="" gid="" shell=/bin/bash home="" skel=""
while [ $# -gt 1 ]; do
  case "$1" in
    -m) m=1; shift ;; -u) uid=$2; shift 2 ;; -g) gid=$2; shift 2 ;;
    -s) shell=$2; shift 2 ;; -d) home=$2; shift 2 ;; -k) skel=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
name=$1
case "$gid" in *[!0-9]*) gid=$(awk -F: -v n="$gid" '"'"'$1==n {print $3}'"'"' "$E/group") ;; esac
printf "%s:x:%s:%s::%s:%s\n" "$name" "$uid" "$gid" "$home" "$shell" >>"$E/passwd"
printf "%s:!:20000:0:99999:7:::\n" "$name" >>"$E/shadow"
if [ $m = 1 ] && [ ! -e "$home" ]; then mkdir -p "$home"; chmod 0700 "$home"; [ -n "$skel" ] && cp -a "$skel"/. "$home"/; fi
exit 0'
write_stub groupadd "$E"'
gid=""; if [ "$1" = -g ]; then gid=$2; shift 2; fi
[ -n "$gid" ] || gid=1777
printf "%s:x:%s:\n" "$1" "$gid" >>"$E/group"'
# usermod -l also renames the user in group member lists (like the real one),
# never in subuid/subgid (the tool must fix those itself).
write_stub usermod "$E"'
case "$*" in ${FAKE_FAIL_USERMOD:-@none@}) echo "usermod stub: injected failure" >&2; exit 1 ;; esac
case "$1" in
  -aG)
    for g in $(printf "%s" "$2" | tr , " "); do
      awk -F: -v g="$g" -v u="$3" '"'"'BEGIN{OFS=":"} $1==g && (","$4",") !~ (","u",") {$4 = ($4=="" ? u : $4","u)} {print}'"'"' "$E/group" >"$E/group.t" && mv "$E/group.t" "$E/group"
    done ;;
  -l)
    awk -F: -v n="$2" '"'"'$1==n {f=1} END {exit !f}'"'"' "$E/passwd" && exit 9
    awk -F: -v o="$3" '"'"'$1==o {f=1} END {exit !f}'"'"' "$E/passwd" || exit 6
    for f in passwd shadow; do
      awk -F: -v o="$3" -v n="$2" '"'"'BEGIN{OFS=":"} $1==o {$1=n} {print}'"'"' "$E/$f" >"$E/$f.t" && mv "$E/$f.t" "$E/$f"
    done
    awk -F: -v o="$3" -v n="$2" '"'"'BEGIN{OFS=":"} { k=split($4, m, ","); s=""; for (i=1;i<=k;i++) { if (m[i]==o) m[i]=n; s = s (i>1 ? "," : "") m[i] }; $4=s; print }'"'"' "$E/group" >"$E/group.t" && mv "$E/group.t" "$E/group" ;;
  -d)
    home=$2; shift 2; mv=0; if [ "$1" = -m ]; then mv=1; shift; fi; name=$1
    old=$(awk -F: -v n="$name" '"'"'$1==n {print $6}'"'"' "$E/passwd")
    if [ $mv = 1 ] && [ -d "$old" ]; then [ -e "$home" ] && exit 12; mv "$old" "$home" || exit 12; fi
    awk -F: -v n="$name" -v h="$home" '"'"'BEGIN{OFS=":"} $1==n {$6=h} {print}'"'"' "$E/passwd" >"$E/passwd.t" && mv "$E/passwd.t" "$E/passwd" ;;
  *) exit 2 ;;
esac'
write_stub groupmod "$E"'
case "$*" in ${FAKE_FAIL_GROUPMOD:-@none@}) exit 1 ;; esac
[ "$1" = -n ] || exit 2
awk -F: -v n="$2" '"'"'$1==n {f=1} END {exit !f}'"'"' "$E/group" && exit 9
awk -F: -v o="$3" -v n="$2" '"'"'BEGIN{OFS=":"} $1==o {$1=n} {print}'"'"' "$E/group" >"$E/group.t" && mv "$E/group.t" "$E/group"'
write_stub passwd 'exit 0'
write_stub chpasswd 'cat >/dev/null'
write_stub runuser '[ "$1" = -u ] || exit 2; shift 2; [ "$1" = -- ] && shift; exec "$@"'
write_stub chown 'exit 0'
# loginctl behaves like logind: disable-linger removes the marker file.
write_stub loginctl '
case "$1" in
  disable-linger) rm -f "$OMARCHY_LINGER_DIR/$2" ;;
  enable-linger) mkdir -p "$OMARCHY_LINGER_DIR"; : >"$OMARCHY_LINGER_DIR/$2" ;;
esac'
write_stub systemctl '
case "$1" in
  is-active) exit "${FAKE_MANAGER_ACTIVE:-3}" ;;
  stop) [ -n "${FAKE_PGREP_FILE:-}" ] && : >"$FAKE_PGREP_FILE" ;;
esac
exit 0'
write_stub pgrep '[ -n "${FAKE_PGREP_FILE:-}" ] && [ -f "$FAKE_PGREP_FILE" ] && cat "$FAKE_PGREP_FILE"; exit 0'
write_stub git 'exit "${FAKE_GIT_RC:-0}"'
write_stub pacman-init 'exit 0'

REAL_PATH="$PATH"
export PATH="$FAKEBIN:$PATH"
export OMARCHY_PASSWD_ROOT="$SB"
export OMARCHY_SENTINEL_DIR="$SB/var/lib/omarchy"
export OMARCHY_USER_CONF="$SB/etc/omarchy-user.conf"
export OMARCHY_WSL_CONF="$SB/etc/wsl.conf"
export OMARCHY_SUDOERS_DIR="$SB/etc/sudoers.d"
export OMARCHY_SUDOERS_MAIN="$SB/etc/sudoers"
export OMARCHY_LINGER_DIR="$SB/var/lib/systemd/linger"
export OMARCHY_HOME_ROOT="$SB/home"
export OMARCHY_SKEL_DIR="$SB/etc/skel"
export OMARCHY_LOCK_FILE="$SB/run/omarchy/account.lock"
export OMARCHY_TENANT_ROOT="$SB/var/lib/omarchy/tenants"
export OMARCHY_SPOOL_DIR="$SB/var/spool"
export OMARCHY_PROC_ROOT="$T/proc"
export OMARCHY_PACMAN_INIT="$FAKEBIN/pacman-init" OMARCHY_DRVFS_ROOTS="$T/nodrvfs" OMARCHY_PROC_CMDLINE="$T/nocmdline"
export OMARCHY_SHIMS_SETUP="" OMARCHY_USER_CONF_TEMPLATE="$T/no-template"
export OMARCHY_NO_TTY=1 OMARCHY_SYSTEMD_RUNNING=0 OMARCHY_ALLOW_NONROOT=1
export OMARCHY_NOW="2026-01-01T00:00:00Z" NO_COLOR=1
export FAKE_PGREP_FILE="$T/pgrep.pids"

# Fresh sandbox with 'devuser' provisioned by the real OOBE, a cron + mail
# spool, subuid/subgid entries and a git repository with a linked worktree.
provision() {
  local name=devuser
  rm -rf "$SB" "$T/proc"
  rm -f "$LOG"/* "$FAKE_PGREP_FILE"
  mkdir -p "$SB/etc/sudoers.d" "$SB/etc/skel" "$SB/home" "$SB/run" "$SB/var/spool/cron" "$SB/var/spool/mail" "$T/proc"
  chmod 0750 "$SB/etc/sudoers.d"
  printf 'root:x:0:0:root:/root:/bin/bash\nbob:x:1001:1001::%s/home/bob:/bin/bash\n' "$SB" >"$SB/etc/passwd"
  printf 'root:x:0:root\nwheel:x:998:\naudio:x:995:\nbob:x:1001:\ndevs:x:1500:\n' >"$SB/etc/group"
  printf 'root:*:20000:0:99999:7:::\nbob:!:20000:0:99999:7:::\n' >"$SB/etc/shadow"
  printf 'root ALL=(ALL:ALL) ALL\n@includedir %s\n' "$SB/etc/sudoers.d" >"$SB/etc/sudoers"
  chmod 0440 "$SB/etc/sudoers"
  cp "$ROOT_DIR/wsl/wsl.conf" "$SB/etc/wsl.conf"
  cp "$ROOT_DIR/wsl/omarchy-user.conf" "$SB/etc/omarchy-user.conf"
  printf '# skel\n' >"$SB/etc/skel/.bashrc"
  if ! bash "$OOBE" --headless --user "$name" >"$LOG/oobe.out" 2>"$LOG/oobe.err" </dev/null; then
    echo "      provisioning failed:"; sed 's/^/        /' "$LOG/oobe.err"
    return 1
  fi
  printf '%s:100000:65536\n' "$name" >"$SB/etc/subuid"
  printf '%s:100000:65536\n' "$name" >"$SB/etc/subgid"
  printf '* * * * * true\n' >"$SB/var/spool/cron/$name"
  : >"$SB/var/spool/mail/$name"
  local h="$SB/home/$name"
  mkdir -p "$h/repo/.git/worktrees/wt1" "$h/wt1"
  printf '%s/wt1/.git\n' "$h" >"$h/repo/.git/worktrees/wt1/gitdir"
  printf 'gitdir: %s/repo/.git/worktrees/wt1\n' "$h" >"$h/wt1/.git"
  : >"$LOG/calls"
}

OUT="$T/out" ERR="$T/err" RC=0
run_tool() { bash "$TOOL" "$@" >"$OUT" 2>"$ERR" </dev/null; RC=$?; }
owner() { awk -F: '$3==1000 {print $1; exit}' "$SB/etc/passwd"; }
calls_has() { grep -Eq "$1" "$LOG/calls" 2>/dev/null; }
line_of() { grep -nE "$1" "$LOG/calls" | head -n 1 | cut -d: -f1; }
in_order() {
  local prev=0 n p
  for p in "$@"; do
    n="$(line_of "$p")"
    [[ -n "$n" ]] || { echo "      missing call: $p"; return 1; }
    (( n > prev )) || { echo "      out of order: $p"; return 1; }
    prev=$n
  done
}
tree_hash() { (cd "$SB" && find . -printf '%y %m %p -> %l\n' | sort && find . -type f -exec sha256sum {} + | sort) | sha256sum | cut -d' ' -f1; }
# Everything the tool may touch, excluding its own backups and lock file.
state_hash() {
  (cd "$SB" && {
    cat etc/passwd etc/group etc/shadow etc/subuid etc/subgid etc/sudoers 2>/dev/null
    find etc/sudoers.d var/lib/systemd/linger home var/spool -printf '%y %m %p -> %l\n' 2>/dev/null | sort
    find etc/sudoers.d home var/spool -type f -exec sha256sum {} + 2>/dev/null | sort
    for f in etc/wsl.conf etc/omarchy-user.conf var/lib/omarchy/oobe_completed; do [[ -f "$f" ]] && sha256sum "$f"; done
  }) | sha256sum | cut -d' ' -f1
}
sudo_rules() { grep -hv '^[[:space:]]*#' "$SB/etc/sudoers.d/"* 2>/dev/null | sed '/^[[:space:]]*$/d'; }

# =============================================================================
header "Static checks"
# =============================================================================
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck -x bin/omarchy-rename-owner" shellcheck -x "$TOOL"
else
  skip "shellcheck not installed"
fi
check "never rm -r / rm -rf a path" bash -c "! grep -nE '^[^#]*\\brm[[:space:]]+(-[a-zA-Z]*r|--recursive)' '$TOOL'"
check "never pkill/kill the owner's processes" bash -c "! grep -nE '^[^#]*\\b(pkill|killall)\\b' '$TOOL'"
check "no uid/gid renumbering (usermod -u / groupmod -g)" bash -c "! grep -nE '^[^#]*(usermod[^#]*-u |groupmod[^#]*-g )' '$TOOL'"
check "never writes Windows files (.wslconfig / registry)" bash -c "! grep -nE '^[^#]*(reg\\.exe|\\.wslconfig[^ ]*[[:space:]]*>)' '$TOOL'"

# =============================================================================
header "CLI contract"
# =============================================================================
provision || exit 1
run_tool --help;      check "--help exits 0 with usage on stdout" bash -c "[[ $RC -eq 0 ]] && grep -q '^Usage: omarchy-rename-owner' '$OUT'"
run_tool --version;   check "--version exits 0" bash -c "[[ $RC -eq 0 ]] && grep -q '^omarchy-rename-owner ' '$OUT'"
run_tool --bogus x;   check "unknown option exits 2 with usage on stderr" bash -c "[[ $RC -eq 2 ]] && grep -q 'Usage:' '$ERR'"
run_tool;             check "missing <new-name> exits 2" test "$RC" -eq 2
run_tool a b;         check "two names exit 2" test "$RC" -eq 2
run_tool --from;      check "--from without a value exits 2" test "$RC" -eq 2
nonroot_run() {
  if [[ "$(id -u)" -ne 0 ]]; then
    OMARCHY_ALLOW_NONROOT=0 bash "$TOOL" "$@" >"$OUT" 2>"$ERR" </dev/null; RC=$?
  else
    setpriv --reuid="$(id -u tester)" --regid="$(id -g tester)" --clear-groups \
      env OMARCHY_ALLOW_NONROOT=0 bash "$TOOL" "$@" >"$OUT" 2>"$ERR" </dev/null; RC=$?
  fi
}
if [[ "$(id -u)" -ne 0 ]] || { id tester >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1; }; then
  nonroot_run -y jane
  check "not root: exit 3 with the exact wsl.exe root-session command" \
    bash -c "[[ $RC -eq 3 ]] && grep -q 'wsl.exe -d Omarchy -u root -- omarchy-rename-owner -y jane' '$ERR'"
  WSL_DISTRO_NAME=Dev-Box nonroot_run jane
  check "not root: the hint names \$WSL_DISTRO_NAME" grep -q 'wsl.exe -d Dev-Box -u root -- omarchy-rename-owner jane' "$ERR"
else
  skip "not-root check: no unprivileged user to switch to"
fi

# =============================================================================
header "Name validation (strict: reject, never transliterate)"
# =============================================================================
mkdir -p "$SB/home/taken" "$OMARCHY_TENANT_ROOT/guest"
for bad in Jane "$(printf 'j%.0s' {1..32})" root bob devs taken guest jösé 1abc "a b" "../x" -lead; do
  run_tool -y -- "$bad"
  if [[ $RC -eq 3 ]] && ! calls_has '^usermod -l'; then
    pass "rejected '${bad:0:14}' (exit 3, nothing run)"
  else
    fail "rejected '${bad:0:14}' (exit $RC)"
  fi
done
run_tool --dry-run jane-doe
check "hyphenated name 'jane-doe' accepted (dry run exit 0)" test "$RC" -eq 0
# "nothing run" = no command beyond the read-only process listing (pgrep).
mutations() { grep -v '^pgrep ' "$LOG/calls" 2>/dev/null; }
: >"$LOG/calls"; run_tool -y devuser
check "renaming to the current name: exit 0, nothing to do, nothing run" \
  bash -c "[[ $RC -eq 0 ]] && grep -q 'nothing to do' '$OUT' && [[ -z \"\$(grep -v '^pgrep ' '$LOG/calls')\" ]]"
rmdir "$SB/home/taken" "$OMARCHY_TENANT_ROOT/guest"

# =============================================================================
header "Dry run: ordered plan, sandbox byte-identical"
# =============================================================================
provision || exit 1
h0="$(tree_hash)"
run_tool --dry-run jane
check "--dry-run exits 0" test "$RC" -eq 0
check "--dry-run: nothing created, modified or removed (sha256 of the whole sandbox)" test "$h0" == "$(tree_hash)"
check "--dry-run: no command executed (only the read-only pgrep)" test -z "$(mutations)"
check "--dry-run: plan lists the 13 steps in order" bash -c "[[ \$(grep -cE '^ +[0-9]+\\. ' '$OUT') -eq 13 ]] && grep -q 'usermod -l jane devuser' '$OUT' && grep -q 'groupmod -n jane devuser' '$OUT'"
run_tool --dry-run --json jane
check "--dry-run --json: one valid JSON document (13 steps, result planned)" \
  python3 -c "import json,sys; d=json.load(open('$OUT')); sys.exit(0 if len(d['steps'])==13 and d['result']=='planned' and d['old']=='devuser' and d['new']=='jane' else 1)"

# =============================================================================
header "Rename under systemd: ordered, journaled, verified"
# =============================================================================
provision || exit 1
mkdir -p "$T/proc/4242"; printf '0::/user.slice/user-1000.slice/user@1000.service/init.scope\n' >"$T/proc/4242/cgroup"
printf 'systemd\n' >"$T/proc/4242/comm"; printf '4242\n' >"$FAKE_PGREP_FILE"
OMARCHY_SYSTEMD_RUNNING=1 FAKE_MANAGER_ACTIVE=0 run_tool -y jane
check "exit 0" test "$RC" -eq 0
check "commands ran in the planned order" in_order \
  '^loginctl disable-linger devuser$' '^systemctl stop user@1000.service$' '^usermod -l jane devuser$' \
  '^groupmod -n jane devuser$' "^usermod -d $SB/home/jane -m jane$" \
  "^runuser -u jane -- git -C $SB/home/jane/repo worktree repair $SB/home/jane/wt1$" '^loginctl enable-linger jane$'
check_eq "passwd: jane has uid 1000 and the new home" "jane:x:1000:1000::$SB/home/jane:/bin/bash" "$(awk -F: '$1=="jane"' "$SB/etc/passwd")"
check "group renamed (gid unchanged) and memberships follow" bash -c "grep -q '^jane:x:1000:' '$SB/etc/group' && grep -q '^wheel:x:998:jane$' '$SB/etc/group'"
check "subuid/subgid entries renamed by the tool" bash -c "grep -qx 'jane:100000:65536' '$SB/etc/subuid' && grep -qx 'jane:100000:65536' '$SB/etc/subgid'"
check "home moved; /home/devuser is a compat symlink to it" bash -c "[[ -d '$SB/home/jane' && ! -L '$SB/home/jane' && \$(readlink '$SB/home/devuser') == '$SB/home/jane' ]]"
check_eq "sudoers: 10-jane holds only the owner rule (mode kept)" "jane ALL=(ALL:ALL) NOPASSWD: ALL" "$(sudo_rules)"
check "sudoers: 10-devuser removed, whole config passes visudo" bash -c "[[ ! -e '$SB/etc/sudoers.d/10-devuser' ]] && visudo -cqf '$SB/etc/sudoers'"
check "linger: marker moved to jane" bash -c "[[ -f '$SB/var/lib/systemd/linger/jane' && ! -e '$SB/var/lib/systemd/linger/devuser' ]]"
check "wsl.conf [user] default = jane" grep -qx 'default = jane' "$SB/etc/wsl.conf"
check "sentinel: PROVISIONED_USER=jane, written by the tool, still uid-keyed" \
  bash -c "grep -qx PROVISIONED_USER=jane '$OMARCHY_SENTINEL_DIR/oobe_completed' && grep -qx WRITTEN_BY=omarchy-rename-owner '$OMARCHY_SENTINEL_DIR/oobe_completed' && grep -qx PROVISIONED_UID=1000 '$OMARCHY_SENTINEL_DIR/oobe_completed'"
check "user.conf: DEFAULT_USER=jane, documented keys kept" bash -c "grep -qx DEFAULT_USER=jane '$OMARCHY_USER_CONF' && grep -qx 'OMARCHY_HOME_DIRS=\"\"' '$OMARCHY_USER_CONF'"
check "cron and mail spools renamed" bash -c "[[ -f '$SB/var/spool/cron/jane' && -e '$SB/var/spool/mail/jane' && ! -e '$SB/var/spool/cron/devuser' ]]"
check "journal closed into the backup directory" bash -c "[[ ! -e '$OMARCHY_SENTINEL_DIR/rename-owner.journal' ]] && ls '$OMARCHY_SENTINEL_DIR'/backups/rename-owner-*/journal.done >/dev/null"
check "backups hold passwd/shadow/group/sudoers/wsl.conf/sentinel" bash -c "cd '$OMARCHY_SENTINEL_DIR'/backups/rename-owner-* && ls | grep -q 'passwd' && ls | grep -q 'shadow' && ls | grep -q 'sudoers.d%10-devuser' && ls | grep -q 'wsl.conf' && ls | grep -q 'oobe_completed'"
check "Windows follow-ups printed, never executed" bash -c "grep -q 'wsl.exe --terminate Omarchy' '$OUT' && ! grep -q '^wsl.exe' '$LOG/calls'"
h1="$(tree_hash)"; : >"$LOG/calls"
run_tool -y jane
check "second run: exit 0, nothing to do, nothing run" \
  bash -c "[[ $RC -eq 0 ]] && grep -q 'nothing to do' '$OUT' && [[ -z \"\$(grep -v '^pgrep ' '$LOG/calls')\" ]]"
check "second run: sandbox byte-identical" test "$h1" == "$(tree_hash)"
run_tool -y --from bob jane2
check "--from naming someone else: exit 3" bash -c "[[ $RC -eq 3 ]] && grep -q \"not 'bob'\" '$ERR'"
run_tool -y --no-compat-symlink devuser
check "rename back over our own compat symlink works" bash -c "[[ $RC -eq 0 ]] && [[ \$(awk -F: '\$3==1000{print \$1}' '$SB/etc/passwd') == devuser ]] && [[ -d '$SB/home/devuser' && ! -L '$SB/home/devuser' ]] && [[ ! -e '$SB/home/jane' ]]"

# =============================================================================
header "Preconditions: sessions, confirmation, lock, JSON"
# =============================================================================
provision || exit 1
mkdir -p "$T/proc/4343"; printf '0::/user.slice/user-1000.slice/session-3.scope\n' >"$T/proc/4343/cgroup"
printf 'bash\n' >"$T/proc/4343/comm"; printf '4343\n' >"$FAKE_PGREP_FILE"
run_tool -y jane
check "a live uid-1000 session (not the user manager): exit 3, lists it, nothing run" \
  bash -c "[[ $RC -eq 3 ]] && grep -q '4343(bash)' '$ERR' && grep -q 'tmux kill-server' '$ERR' && ! grep -q '^usermod' '$LOG/calls'"
rm -f "$FAKE_PGREP_FILE"
run_tool jane
check "no --yes and no terminal: exit 3, nothing run" bash -c "[[ $RC -eq 3 ]] && grep -q -- '--yes' '$ERR' && ! grep -q '^usermod' '$LOG/calls'"
if command -v flock >/dev/null 2>&1; then
  set -m; flock "$OMARCHY_LOCK_FILE" sleep 30 & lockpid=$!; set +m
  BG_PIDS+=("$lockpid"); sleep 0.3
  run_tool -y jane
  check "lock held by an OOBE/rename: exit 75" test "$RC" -eq 75
  # flock's child (sleep) holds the lock too: kill the whole process group.
  kill -- -"$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null
else
  skip "flock not installed"
fi
run_tool -y --json jane
check "--json run: a single JSON document, result renamed" \
  python3 -c "import json,sys; d=json.load(open('$OUT')); sys.exit(0 if d['result']=='renamed' and d['new']=='jane' else 1)"

# =============================================================================
header "Rollback after a fault at every step (state restored exactly)"
# =============================================================================
for step in stop-user-manager rename-login subids rename-group move-home git-repair compat-symlink sudoers linger wsl-conf sentinel spool verify; do
  provision || exit 1
  sysd=0
  if [[ "$step" == "stop-user-manager" ]]; then sysd=1; fi
  before="$(state_hash)"
  OMARCHY_SYSTEMD_RUNNING=$sysd FAKE_MANAGER_ACTIVE=3 OMARCHY_FAULT_AT=$step run_tool -y jane
  after="$(state_hash)"
  if [[ $RC -eq 1 && "$before" == "$after" && "$(owner)" == devuser && ! -e "$OMARCHY_SENTINEL_DIR/rename-owner.journal" ]] \
     && grep -q 'rolled back' "$ERR"; then
    pass "fault after '$step': exit 1, every change rolled back"
  else
    fail "fault after '$step': rc=$RC owner=$(owner) state $( [[ "$before" == "$after" ]] && echo same || echo DIFFERENT)"
  fi
done
provision || exit 1
OMARCHY_SYSTEMD_RUNNING=1 FAKE_MANAGER_ACTIVE=3 OMARCHY_FAULT_AT=linger run_tool -y jane
check "rollback under systemd re-enables lingering for the old name" bash -c "[[ $RC -eq 1 ]] && grep -q '^loginctl enable-linger devuser$' '$LOG/calls' && [[ -f '$SB/var/lib/systemd/linger/devuser' ]]"
provision || exit 1
before="$(state_hash)"
FAKE_FAIL_USERMOD="-d *" run_tool -y jane
check "a failing usermod -d -m is rolled back (exit 1, state restored)" bash -c "[[ $RC -eq 1 ]] && [[ '$before' == '$(state_hash)' ]]"

# Incomplete rollback (exit 4), then a re-run resumes from the journal.
provision || exit 1
OMARCHY_FAULT_AT=sentinel OMARCHY_FAULT_UNDO=sudoers run_tool -y jane
check "undo failure: exit 4, ROLLBACK INCOMPLETE, journal kept" \
  bash -c "[[ $RC -eq 4 ]] && grep -q 'ROLLBACK INCOMPLETE' '$ERR' && [[ -f '$OMARCHY_SENTINEL_DIR/rename-owner.journal' ]]"
run_tool -y jane
check "re-run resumes the recorded rename and completes it (exit 0)" \
  bash -c "[[ $RC -eq 0 ]] && grep -q 'resuming' '$ERR' && [[ \$(awk -F: '\$3==1000{print \$1}' '$SB/etc/passwd') == jane ]]"
check "resumed rename is consistent (sudoers, wsl.conf, sentinel, no journal)" \
  bash -c "[[ \"\$(grep -hv '^#' '$SB/etc/sudoers.d/'*)\" == 'jane ALL=(ALL:ALL) NOPASSWD: ALL' ]] && grep -qx 'default = jane' '$SB/etc/wsl.conf' && grep -qx PROVISIONED_USER=jane '$OMARCHY_SENTINEL_DIR/oobe_completed' && [[ ! -e '$OMARCHY_SENTINEL_DIR/rename-owner.journal' ]]"
provision || exit 1
OMARCHY_FAULT_AT=sentinel OMARCHY_FAULT_UNDO=sudoers run_tool -y jane
run_tool -y bob2
check "a different name while a rename is unfinished: exit 3 naming the recorded one" bash -c "[[ $RC -eq 3 ]] && grep -q \"unfinished rename to 'jane'\" '$ERR'"

# Signals: the tool pauses after a step; SIGTERM/SIGINT must roll back.
for sig in TERM:143 INT:130; do
  provision || exit 1
  before="$(state_hash)"
  rm -f "$T/paused"
  set -m
  OMARCHY_PAUSE_AT=sudoers OMARCHY_PAUSE_FILE="$T/paused" bash "$TOOL" -y jane >"$OUT" 2>"$ERR" </dev/null &
  pid=$!
  set +m
  for _ in $(seq 1 100); do [[ -e "$T/paused" ]] && break; sleep 0.1; done
  kill -"${sig%%:*}" -- -"$pid" 2>/dev/null
  wait "$pid"; RC=$?
  check "SIG${sig%%:*} mid-rename: exit ${sig#*:}, rolled back, state restored" \
    bash -c "[[ $RC -eq ${sig#*:} ]] && grep -q 'Rolled back' '$ERR' && [[ '$before' == '$(state_hash)' ]]"
done

# =============================================================================
header "Partial and unusual layouts"
# =============================================================================
provision || exit 1
sed -i 's/^devuser:/jane:/' "$SB/etc/passwd" "$SB/etc/shadow"
run_tool -y jane
check "renamed outside the tool, state still names the old account: exit 3 asking for --from" \
  bash -c "[[ $RC -eq 3 ]] && grep -q -- '--from' '$ERR'"
run_tool -y --from devuser jane
check "--from completes the partial rename (group, home, sudoers, linger, wsl.conf, sentinel)" \
  bash -c "[[ $RC -eq 0 ]] && grep -q '^jane:x:1000:' '$SB/etc/group' && [[ -d '$SB/home/jane' ]] && [[ -f '$SB/etc/sudoers.d/10-jane' ]] && [[ -f '$SB/var/lib/systemd/linger/jane' ]] && grep -qx 'default = jane' '$SB/etc/wsl.conf' && grep -qx PROVISIONED_USER=jane '$OMARCHY_SENTINEL_DIR/oobe_completed'"
check "--from: login rename skipped (already done)" bash -c "! grep -q '^usermod -l' '$LOG/calls'"
provision || exit 1
rm -f "$SB/etc/sudoers.d/10-devuser"; printf 'devuser ALL=(ALL) ALL\n' >"$SB/etc/sudoers.d/10-devuser"; chmod 0440 "$SB/etc/sudoers.d/10-devuser"
run_tool -y jane
check "unmanaged 10-<old> drop-in is left alone and reported" bash -c "[[ $RC -eq 0 ]] && [[ -f '$SB/etc/sudoers.d/10-devuser' ]] && grep -q 'not managed by omarchy-wsl' '$ERR'"
provision || exit 1
mkdir -p "$SB/srv"; mv "$SB/home/devuser" "$SB/srv/devuser"
sed -i "s|$SB/home/devuser|$SB/srv/devuser|" "$SB/etc/passwd"
run_tool -y jane
check "home outside /home/<old>: login renamed, home left where it is, no symlink" \
  bash -c "[[ $RC -eq 0 ]] && grep -q '^jane:x:1000:1000::$SB/srv/devuser:' '$SB/etc/passwd' && [[ ! -e '$SB/home/devuser' && ! -e '$SB/home/jane' ]]"
provision || exit 1
rm -f "$SB/etc/sudoers.d/10-devuser" "$SB/var/lib/systemd/linger/devuser"
sed -i '/^\[user\]/,$d' "$SB/etc/wsl.conf"
run_tool -y jane
check "no drop-in, no linger, no [user] default: those steps are skipped, rename succeeds" \
  bash -c "[[ $RC -eq 0 ]] && [[ ! -e '$SB/etc/sudoers.d/10-jane' && ! -e '$SB/var/lib/systemd/linger/jane' ]] && ! grep -q '^default' '$SB/etc/wsl.conf'"

# =============================================================================
# T2: real root inside a throwaway container
# =============================================================================
in_container() {
  [[ -f /run/.containerenv || -f /.dockerenv ]] && return 0
  command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet 2>/dev/null
}
T2_SNAP=""
t2_snapshot() {
  T2_SNAP="$T/t2-snapshot"
  mkdir -p "$T2_SNAP"
  local f
  for f in /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/subuid /etc/subgid /etc/sudoers /etc/wsl.conf /etc/omarchy-user.conf; do
    [[ -f "$f" ]] && cp -p "$f" "$T2_SNAP/$(echo "$f" | tr / %)"
  done
  ls -A /etc/sudoers.d >"$T2_SNAP/sudoers.d.list" 2>/dev/null || true
  ls -A /home >"$T2_SNAP/home.list" 2>/dev/null || true
}
t2_restore() {
  [[ -n "$T2_SNAP" && -d "$T2_SNAP" ]] || return 0
  local f b
  pkill -u 1000 2>/dev/null || true
  for b in "$T2_SNAP"/%*; do
    [[ -f "$b" ]] || continue
    cp -p "$b" "$(basename "$b" | tr % /)"
  done
  [[ -f "$T2_SNAP/%etc%wsl.conf" ]] || rm -f /etc/wsl.conf
  [[ -f "$T2_SNAP/%etc%omarchy-user.conf" ]] || rm -f /etc/omarchy-user.conf
  for f in /etc/sudoers.d/*; do grep -qx "$(basename "$f")" "$T2_SNAP/sudoers.d.list" || rm -f "$f"; done
  for f in /home/devuser /home/jane; do
    if ! grep -qx "$(basename "$f")" "$T2_SNAP/home.list"; then
      if [[ -L "$f" ]]; then rm -f "$f"; else rm -rf "$f"; fi
    fi
  done
  rm -rf /var/lib/omarchy /var/lib/systemd/linger/devuser /var/lib/systemd/linger/jane \
         /usr/lib/omarchy-wsl/account.sh /usr/lib/omarchy-wsl/common.sh
  T2_SNAP=""
}
t2_rename() {
  header "T2 real root: usermod/groupmod/visudo/git in a throwaway container"
  local o tool_env
  local PATH="$REAL_PATH"
  t2_snapshot
  o="$(getent passwd 1000 | cut -d: -f1)"
  [[ -n "$o" ]] && userdel "$o" >/dev/null 2>&1
  install -d /usr/lib/omarchy-wsl
  install -m 0644 "$ACCOUNT_LIB" /usr/lib/omarchy-wsl/account.sh
  install -m 0644 "$COMMON_LIB" /usr/lib/omarchy-wsl/common.sh
  local -a clean=(env -i "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" HOME=/root NO_COLOR=1
                  OMARCHY_PACMAN_INIT= OMARCHY_DRVFS_ROOTS=/nonexistent OMARCHY_SHIMS_SETUP=)
  "${clean[@]}" bash "$OOBE" --headless --user devuser </dev/null >"$OUT" 2>"$ERR"
  check "T2: owner provisioned by the real OOBE" test "$(getent passwd 1000 | cut -d: -f1)" == devuser
  runuser -u devuser -- bash -c 'cd ~ && git init -q repo && cd repo && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init && git worktree add -q ../wt1' >/dev/null 2>&1
  printf '* * * * * true\n' >/tmp/omw-cron && install -D -m 0600 /tmp/omw-cron /var/spool/cron/devuser && rm -f /tmp/omw-cron
  tool_env=("${clean[@]}")

  local before
  before="$(getent passwd 1000; getent group 1000; ls -la /home; cat /etc/sudoers.d/10-devuser /etc/wsl.conf)"
  "${tool_env[@]}" OMARCHY_FAULT_AT=sentinel bash "$TOOL" -y jane </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2: fault after 'sentinel' with real tools: exit 1, fully restored" \
    bash -c "[[ $RC -eq 1 ]] && [[ \"\$(getent passwd 1000; getent group 1000; ls -la /home; cat /etc/sudoers.d/10-devuser /etc/wsl.conf)\" == \"\$1\" ]]" _ "$before"
  check "T2: worktrees point at the old paths again after the rollback" runuser -u devuser -- git -C /home/devuser/repo worktree list --porcelain

  runuser -u devuser -- sleep 60 &
  BG_PIDS+=($!); sleep 0.5
  "${tool_env[@]}" bash "$TOOL" -y jane </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2: refuses while a real uid-1000 process runs (exit 3)" bash -c "[[ $RC -eq 3 ]] && grep -q '(sleep)' '$ERR'"
  pkill -u 1000 sleep 2>/dev/null; sleep 0.5

  "${tool_env[@]}" bash "$TOOL" -y jane </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2: rename devuser -> jane exits 0" test "$RC" -eq 0
  check_eq "T2: getent passwd 1000" "jane:x:1000:1000::/home/jane:/bin/bash" "$(getent passwd 1000)"
  check_eq "T2: getent group 1000" "jane" "$(getent group 1000 | cut -d: -f1)"
  check_eq "T2: home moved, 0700 jane:jane" "700 jane:jane" "$(stat -c '%a %U:%G' /home/jane)"
  check_eq "T2: compat symlink /home/devuser -> /home/jane" "/home/jane" "$(readlink /home/devuser)"
  check "T2: visudo -c accepts the configuration" visudo -cq
  check "T2: passwordless sudo works as jane" runuser -u jane -- sudo -n true
  check_eq "T2: su - jane lands in the new home" "/home/jane" "$(su - jane -c pwd 2>/dev/null)"
  check_eq "T2: worktree .git repaired to the new path" "gitdir: /home/jane/repo/.git/worktrees/wt1" "$(cat /home/jane/wt1/.git)"
  check_eq "T2: main repository records the new worktree path" "/home/jane/wt1/.git" "$(cat /home/jane/repo/.git/worktrees/wt1/gitdir)"
  check "T2: cron spool renamed" test -f /var/spool/cron/jane
  check "T2: wsl.conf, sentinel, user.conf say jane" \
    bash -c "grep -qx 'default = jane' /etc/wsl.conf && grep -qx PROVISIONED_USER=jane /var/lib/omarchy/oobe_completed && grep -qx DEFAULT_USER=jane /etc/omarchy-user.conf"
  "${tool_env[@]}" bash "$TOOL" -y jane </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2: second run is a no-op" bash -c "[[ $RC -eq 0 ]] && grep -q 'nothing to do' '$OUT'"
  set -m
  "${tool_env[@]}" OMARCHY_PAUSE_AT=linger OMARCHY_PAUSE_FILE="$T/t2.paused" bash "$TOOL" -y devuser </dev/null >"$OUT" 2>"$ERR" &
  local pid=$!
  set +m
  for _ in $(seq 1 100); do [[ -e "$T/t2.paused" ]] && break; sleep 0.1; done
  kill -TERM -- -"$pid" 2>/dev/null; wait "$pid"; RC=$?
  check "T2: SIGTERM during a real rename back: exit 143, jane restored" \
    bash -c "[[ $RC -eq 143 ]] && [[ \"\$(getent passwd 1000)\" == 'jane:x:1000:1000::/home/jane:/bin/bash' ]] && [[ -f /etc/sudoers.d/10-jane ]]"
  "${tool_env[@]}" bash "$TOOL" -y --no-compat-symlink devuser </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2: rename back over the compat symlink works" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(getent passwd 1000 | cut -d: -f1)\" == devuser ]] && [[ -d /home/devuser && ! -L /home/devuser && ! -e /home/jane ]]"
  check_eq "T2: worktree repaired back" "gitdir: /home/devuser/repo/.git/worktrees/wt1" "$(cat /home/devuser/wt1/.git)"
  t2_restore
}

if [[ "${OMW_REAL_ROOT:-auto}" == "0" ]]; then
  :
elif [[ "$(id -u)" -eq 0 ]] && in_container; then
  t2_rename
elif [[ "${OMW_STRICT:-}" == "1" ]]; then
  header "T2 real root"
  fail "T2 real-root tier required (OMW_STRICT=1) but not running as root inside a container"
else
  header "T2 real root"
  skip "T2 real-root tier: needs root inside a throwaway container"
fi

printf '\n'
echo "Rename Owner Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-}" == "1" ]]; then exit 1; fi
exit 0
