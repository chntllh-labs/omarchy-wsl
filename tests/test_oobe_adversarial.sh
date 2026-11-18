#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: OOBE & Owner-Account Adversarial Suite
# /tests/test_oobe_adversarial.sh
# ==============================================================================
# Runs the REAL code, never copies of it:
#   T1 (always, no root needed): wsl/oobe.sh main() and lib/omarchy-wsl-account.sh
#      against a sandbox. A fake passwd/group/shadow lives under
#      OMARCHY_PASSWD_ROOT and recorder stubs (useradd, groupadd, usermod,
#      passwd, chpasswd, runuser, chown, loginctl, systemctl, cmd.exe, Omarchy
#      helpers) sit first on PATH. Every sudoers file is checked with the real
#      visudo.
#   T2 (root inside a throwaway container): real useradd/visudo/runuser against
#      the container's /etc, the exact CI command
#      `oobe.sh --headless --user devuser`, and the profile.d hook through a pty.
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
OOBE="$ROOT_DIR/wsl/oobe.sh"
ACCOUNT_LIB="$ROOT_DIR/lib/omarchy-wsl-account.sh"
COMMON_LIB="$ROOT_DIR/lib/omarchy-wsl-common.sh"
HOOK="$ROOT_DIR/wsl/profile.d/00-omarchy-firstboot.sh"

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

# The CI image sets DEBIAN_FRONTEND=noninteractive and CI runners set CI=true;
# both force headless mode, which the interactive tests must not inherit.
unset CI DEBIAN_FRONTEND SSH_CONNECTION SSH_TTY OMARCHY_USER WSLENV USERNAME OMARCHY_WSL_LIB_DIR

T="$(mktemp -d "${TMPDIR:-/tmp}/omw-oobe.XXXXXX")"
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
MNT="$T/mnt"
mkdir -p "$LOG" "$FAKEBIN" "$MNT/c/Windows/System32"

# -----------------------------------------------------------------------------
# Recorder stubs. Each appends "<cmd> <argv...>" to $LOG/calls.
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
    *) echo "useradd stub: unsupported $1" >&2; exit 2 ;;
  esac
done
name=$1
if awk -F: -v n="$name" -v u="$uid" '"'"'$1==n || $3==u {f=1} END {exit !f}'"'"' "$E/passwd"; then echo "useradd: exists" >&2; exit 9; fi
case "$gid" in *[!0-9]*) g=$(awk -F: -v n="$gid" '"'"'$1==n {print $3}'"'"' "$E/group"); [ -n "$g" ] || exit 6; gid=$g ;; esac
printf "%s:x:%s:%s::%s:%s\n" "$name" "$uid" "$gid" "$home" "$shell" >>"$E/passwd"
printf "%s:!:20000:0:99999:7:::\n" "$name" >>"$E/shadow"
if [ $m = 1 ]; then
  if [ -e "$home" ]; then echo "useradd: warning: $home exists" >&2
  else mkdir -p "$home"; chmod 0700 "$home"; [ -n "$skel" ] && cp -a "$skel"/. "$home"/; fi
fi
exit 0'

write_stub groupadd "$E"'
gid=""; if [ "$1" = -g ]; then gid=$2; shift 2; fi
name=$1
awk -F: -v n="$name" '"'"'$1==n {f=1} END {exit !f}'"'"' "$E/group" && exit 9
if [ -z "$gid" ]; then
  gid=1000
  while awk -F: -v g="$gid" '"'"'$3==g {f=1} END {exit !f}'"'"' "$E/group"; do gid=$((gid+1)); done
fi
awk -F: -v g="$gid" '"'"'$3==g {f=1} END {exit !f}'"'"' "$E/group" && exit 4
printf "%s:x:%s:\n" "$name" "$gid" >>"$E/group"'

write_stub usermod "$E"'
case "$*" in ${FAKE_FAIL_USERMOD:-@none@}) echo "usermod stub: injected failure" >&2; exit 1 ;; esac
rename_in() { awk -F: -v o="$2" -v n="$3" '"'"'BEGIN{OFS=":"} $1==o {$1=n} {print}'"'"' "$1" >"$1.t" && mv "$1.t" "$1"; }
case "$1" in
  -aG)
    for g in $(printf "%s" "$2" | tr , " "); do
      awk -F: -v g="$g" -v u="$3" '"'"'BEGIN{OFS=":"} $1==g && (","$4",") !~ (","u",") {$4 = ($4=="" ? u : $4","u)} {print}'"'"' "$E/group" >"$E/group.t" && mv "$E/group.t" "$E/group"
    done ;;
  -l)
    awk -F: -v n="$2" '"'"'$1==n {f=1} END {exit !f}'"'"' "$E/passwd" && exit 9
    awk -F: -v o="$3" '"'"'$1==o {f=1} END {exit !f}'"'"' "$E/passwd" || exit 6
    rename_in "$E/passwd" "$3" "$2"; rename_in "$E/shadow" "$3" "$2" ;;
  -d)
    home=$2; shift 2; mv=0; if [ "$1" = -m ]; then mv=1; shift; fi; name=$1
    old=$(awk -F: -v n="$name" '"'"'$1==n {print $6}'"'"' "$E/passwd")
    if [ $mv = 1 ] && [ -d "$old" ]; then [ -e "$home" ] && exit 12; mv "$old" "$home" || exit 12; fi
    awk -F: -v n="$name" -v h="$home" '"'"'BEGIN{OFS=":"} $1==n {$6=h} {print}'"'"' "$E/passwd" >"$E/passwd.t" && mv "$E/passwd.t" "$E/passwd" ;;
  *) echo "usermod stub: unsupported $*" >&2; exit 2 ;;
esac'

write_stub groupmod "$E"'
case "$*" in ${FAKE_FAIL_GROUPMOD:-@none@}) exit 1 ;; esac
[ "$1" = -n ] || exit 2
awk -F: -v n="$2" '"'"'$1==n {f=1} END {exit !f}'"'"' "$E/group" && exit 9
awk -F: -v o="$3" -v n="$2" '"'"'BEGIN{OFS=":"} $1==o {$1=n} {print}'"'"' "$E/group" >"$E/group.t" && mv "$E/group.t" "$E/group"'

write_stub passwd "$E"'
if [ "$1" = -l ]; then
  awk -F: -v n="$2" '"'"'BEGIN{OFS=":"} $1==n && $2 !~ /^!/ {$2="!"$2} {print}'"'"' "$E/shadow" >"$E/shadow.t" && mv "$E/shadow.t" "$E/shadow"
fi
exit 0'

# chpasswd: records the user and a hash of the password (never the password).
write_stub chpasswd "$E"'
IFS= read -r line
u=${line%%:*}; pw=${line#*:}
printf "%s %s\n" "$u" "$(printf "%s" "$pw" | sha256sum | cut -c1-16)" >>"'"$LOG"'/chpasswd.stdin"
awk -F: -v n="$u" '"'"'BEGIN{OFS=":"} $1==n {$2="$6$fakehash"} {print}'"'"' "$E/shadow" >"$E/shadow.t" && mv "$E/shadow.t" "$E/shadow"'

write_stub runuser '
[ "$1" = -u ] || exit 2
shift 2
[ "$1" = -- ] && shift
exec "$@"'
write_stub chown 'exit 0'
write_stub loginctl 'exit 0'
write_stub systemctl 'case "$1" in is-active) exit "${FAKE_MANAGER_ACTIVE:-3}" ;; esac; exit 0'
write_stub pacman-init 'if [ -n "${FAKE_PACMAN_MARK:-}" ]; then : >"$FAKE_PACMAN_MARK"; fi; sleep "${FAKE_PACMAN_SLEEP:-0}"'
write_stub omarchy-nvim-setup 'printf "%s\n" "nvim HOME=$HOME USER=$USER" >>"'"$LOG"'/env"'
write_stub omarchy-theme-set 'printf "%s\n" "theme HOME=$HOME USER=$USER BRIDGE=${OMARCHY_WSL_THEME_BRIDGE:-} ARG=$1" >>"'"$LOG"'/env"; mkdir -p "$HOME/.local/state/omarchy/current"; printf "%s\n" "$1" >"$HOME/.local/state/omarchy/current/theme.name"'
write_stub mise 'exit 0'
write_stub omarchy-dns-sync 'sleep "${FAKE_SYNC_SLEEP:-0}"'
write_stub omarchy-ca-sync 'exit 0'
write_stub omarchy-proxy-sync 'exit 0'
write_stub wsl-shims-setup 'printf "%s\n" "shims WSL_INTEROP=${WSL_INTEROP:-} uid=$(id -u)" >>"'"$LOG"'/env"; sleep "${FAKE_SHIMS_SLEEP:-0}"; exit "${FAKE_SHIMS_RC:-0}"'

# cmd.exe on the fake C: drive: records its cwd, prints a CRLF user name.
cat >"$MNT/c/Windows/System32/cmd.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "cmd.exe cwd=\$PWD \$*" >>"$LOG/calls"
printf '%s\r\n' "\${FAKE_WIN_USER:-Jane Doe}"
EOF
chmod +x "$MNT/c/Windows/System32/cmd.exe"

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
export OMARCHY_PACMAN_INIT="$FAKEBIN/pacman-init"
export OMARCHY_DRVFS_ROOTS="$MNT/c"
export OMARCHY_PROC_CMDLINE="$T/cmdline"
export OMARCHY_SHIMS_SETUP="$FAKEBIN/wsl-shims-setup" OMARCHY_BINFMT_DIR="$T/binfmt"
export OMARCHY_USER_CONF_TEMPLATE="$T/no-template"
export OMARCHY_NO_TTY=1 OMARCHY_SYSTEMD_RUNNING=0 OMARCHY_ALLOW_NONROOT=1
export OMARCHY_NOW="2026-01-01T00:00:00Z" NO_COLOR=1
: >"$T/cmdline"

reset_sandbox() {
  rm -rf "$SB" "$MNT/c/Users"
  rm -f "$LOG"/*
  mkdir -p "$SB/etc/sudoers.d" "$SB/etc/skel" "$SB/home" "$SB/var/lib" "$SB/run"
  chmod 0750 "$SB/etc/sudoers.d"
  cat >"$SB/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1::/:/usr/bin/nologin
daemon:x:2:2::/:/usr/bin/nologin
EOF
  cat >"$SB/etc/group" <<'EOF'
root:x:0:root
games:x:50:
users:x:100:
wheel:x:998:
audio:x:995:
video:x:986:
docker:x:970:
devs:x:1500:
EOF
  printf 'root:*:20000:0:99999:7:::\n' >"$SB/etc/shadow"
  printf 'root ALL=(ALL:ALL) ALL\n@includedir %s\n' "$SB/etc/sudoers.d" >"$SB/etc/sudoers"
  chmod 0440 "$SB/etc/sudoers"
  cp "$ROOT_DIR/wsl/wsl.conf" "$SB/etc/wsl.conf"
  printf '# Omarchy-WSL user configuration\nOMARCHY_HOME_DIRS=""\n' >"$SB/etc/omarchy-user.conf"
  printf '# skel\n' >"$SB/etc/skel/.bashrc"
  printf 'leaked-build-history\n' >"$SB/etc/skel/.bash_history"
  : >"$T/cmdline"
}

OUT="$T/out" ERR="$T/err" RC=0
run_oobe() {
  bash "$OOBE" "$@" >"$OUT" 2>"$ERR" </dev/null
  RC=$?
}
pw_entry() { awk -F: -v k="$1" '$1==k || $3==k {print; exit}' "$SB/etc/passwd"; }
owner() { awk -F: '$3==1000 {print $1; exit}' "$SB/etc/passwd"; }
calls_has() { grep -Eq "$1" "$LOG/calls" 2>/dev/null; }
tree_hash() { (cd "$SB" && find . -printf '%y %m %p\n' | sort && find . -type f -exec sha256sum {} + | sort) | sha256sum | cut -d' ' -f1; }
sudo_rules() { grep -hv '^[[:space:]]*#' "$SB/etc/sudoers.d/"* 2>/dev/null | sed '/^[[:space:]]*$/d'; }

# =============================================================================
header "Static checks"
# =============================================================================
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck -x oobe.sh, account.sh, common.sh" shellcheck -x "$OOBE" "$ACCOUNT_LIB" "$COMMON_LIB"
  check "shellcheck profile.d hook (POSIX sh)" shellcheck -x "$HOOK"
else
  skip "shellcheck not installed"
fi
if command -v dash >/dev/null 2>&1; then
  check "profile.d hook parses under dash (POSIX)" dash -n "$HOOK"
else
  check "profile.d hook parses under bash --posix" bash --posix -n "$HOOK"
fi
check "wsl/00-omarchy-firstboot.sh duplicate is gone" test ! -e "$ROOT_DIR/wsl/00-omarchy-firstboot.sh"
# Code lines only (comments explain what is avoided and why).
check "no iconv transliteration in the OOBE or account library" bash -c "! grep -nE '^[^#]*iconv' '$OOBE' '$ACCOUNT_LIB'"
check "OOBE never empties a password (no passwd -d)" bash -c "! grep -nE '^[^#]*passwd[[:space:]]+-d' '$OOBE' '$ACCOUNT_LIB'"
check "OOBE never pkills the owner" bash -c "! grep -nE '\\bpkill\\b|\\bkillall\\b' '$OOBE'"
check "OOBE no longer copies sysctl/cgroup files at runtime" bash -c "! grep -nE 'sysctl\\.d|build\\.slice|configure_resource_governance' '$OOBE'"
check "user.conf template sets OMARCHY_HOME_DIRS empty" grep -qx 'OMARCHY_HOME_DIRS=""' "$ROOT_DIR/wsl/omarchy-user.conf"
check "wsl-distribution.conf runs /usr/lib/wsl/oobe.sh as uid 1000 default" \
  bash -c "grep -qx 'command = /usr/lib/wsl/oobe.sh' '$ROOT_DIR/wsl/wsl-distribution.conf' && grep -qx 'defaultUid = 1000' '$ROOT_DIR/wsl/wsl-distribution.conf'"

# =============================================================================
header "Account library: transliteration & validation (exact, locale-independent)"
# =============================================================================
# shellcheck source=SCRIPTDIR/../lib/omarchy-wsl-account.sh
source "$ACCOUNT_LIB"
declare -a SAN_CASES=(
  "Müller|muller" "François|francois" "José|jose" "John Doe|john_doe" "AliceSmith|alicesmith"
  "Иван|omarchy" "张伟|omarchy" "🚀|omarchy" "|omarchy" "123agent|u_123agent" "-baduser|baduser"
  "jean-luc|jean-luc" "john - doe|john_doe" "Straße|strasse" "Ærøskøbing|aeroskobing" "Łukasz|lukasz"
  "Đorđe|dorde" "Søren Kierkegaard|soren_kierkegaard" "user@host#1!|user_host_1"
  "  John  Doe.Corp  |john_doe_corp" "ÅSA_ÖBERG|asa_oberg" "Zoë|zoe"
)
for mode in auto table; do
  bad=0
  for c in "${SAN_CASES[@]}"; do
    got="$(OMARCHY_TRANSLIT=$mode sanitize_username "${c%%|*}")"
    if [[ "$got" != "${c#*|}" ]]; then bad=1; echo "      [$mode] '${c%%|*}' -> '$got' (want '${c#*|}')"; fi
  done
  check "sanitize_username: ${#SAN_CASES[@]} exact vectors ($mode)" test $bad -eq 0
done
for loc in C POSIX C.UTF-8; do
  check_eq "sanitize_username identical under LC_ALL=$loc" "muller_francois" "$(LC_ALL=$loc sanitize_username 'Müller François')"
done
check_eq "40-char name truncated to 31" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$(sanitize_username "$(printf 'A%.0s' {1..40})")"
check_eq "python NFKD covers letters outside the table (Nguyễn)" "nguyen" "$(sanitize_username 'Nguyễn')"
check_eq "table-only mode drops letters outside the table" "nguyn" "$(OMARCHY_TRANSLIT=table sanitize_username 'Nguyễn')"
ok=1
for n in alice jane-doe _x9 a; do validate_username "$n" || { [[ "$n" == "_x9" ]] || ok=0; }; done
check "validate_username accepts alice, jane-doe, a" test $ok -eq 1
bad=0
for n in Root root daemon 9abc -x "a b" "../x" "jösé" "$(printf 'b%.0s' {1..32})" systemd-x _private ""; do
  if validate_username "$n"; then bad=1; echo "      accepted '$n'"; fi
done
check "validate_username rejects Root/root/daemon/9abc/-x/'a b'/../x/jösé/32 chars/systemd-*/_*/empty" test $bad -eq 0
check_eq "validate_username caps names at 31 characters" "0" "$(validate_username "$(printf 'c%.0s' {1..31})"; echo $?)"

# =============================================================================
header "Account library: wsl.conf, sentinel, user.conf, sudoers (atomic)"
# =============================================================================
reset_sandbox
omw_acct_init
printf '[boot]\r\nsystemd = true\r\n\r\n[User]\r\ndefault = olduser\r\ndefault = dup\r\n[network]\r\ngenerateResolvConf = true\r\n' >"$OMARCHY_WSL_CONF"
update_wsl_conf_default_user alice
check "wsl.conf: replaces default in [User] (case-insensitive, CRLF file)" grep -q '^default = alice$' "$OMARCHY_WSL_CONF"
check "wsl.conf: duplicate default keys dropped" test "$(grep -c '^default' "$OMARCHY_WSL_CONF")" -eq 1
check "wsl.conf: other sections preserved" grep -q '^generateResolvConf = true' "$OMARCHY_WSL_CONF"
check "wsl.conf: no temp files left" test "$(find "$SB/etc" -maxdepth 1 -name '.wsl.conf.omw.*' | wc -l)" -eq 0
printf '[boot]\nsystemd = true\n' >"$OMARCHY_WSL_CONF"
update_wsl_conf_default_user bob
check_eq "wsl.conf: [user] appended when missing" "bob" "$(wsl_conf_default_user)"
rm -f "$OMARCHY_WSL_CONF"
update_wsl_conf_default_user carol
check_eq "wsl.conf: created when missing" "carol" "$(wsl_conf_default_user)"
check "wsl.conf: refuses an invalid name" bash -c "! (source '$ACCOUNT_LIB'; update_wsl_conf_default_user 'x;rm' 2>/dev/null)"
write_sentinel devuser
check "sentinel keyed on PROVISIONED_UID=1000" grep -qx 'PROVISIONED_UID=1000' "$OMARCHY_SENTINEL_DIR/oobe_completed"
check_eq "sentinel_get PROVISIONED_USER" "devuser" "$(sentinel_get PROVISIONED_USER)"
check "sentinel_get refuses keys outside the whitelist" bash -c "! (source '$ACCOUNT_LIB'; sentinel_get PATH)"
printf '# comment\nOMARCHY_HOME_DIRS="code notes"\nDEFAULT_USER=old\n' >"$OMARCHY_USER_CONF"
write_user_conf devuser
check "user.conf: DEFAULT_USER replaced, comments and OMARCHY_HOME_DIRS kept" \
  bash -c "grep -qx 'DEFAULT_USER=devuser' '$OMARCHY_USER_CONF' && grep -qx '# comment' '$OMARCHY_USER_CONF' && grep -qx 'OMARCHY_HOME_DIRS=\"code notes\"' '$OMARCHY_USER_CONF'"
printf 'DEFAULT_USER=$(id)\n' >"$OMARCHY_USER_CONF"
check_eq "user.conf: hostile DEFAULT_USER ignored, never executed" "" "$(user_conf_default_user 2>/dev/null)"
if command -v visudo >/dev/null 2>&1; then
  configure_sudoers devuser nopasswd
  check_eq "sudoers: passwordless owner-only rule" "devuser ALL=(ALL:ALL) NOPASSWD: ALL" "$(sudo_rules)"
  check_eq "sudoers: mode 0440" "440" "$(stat -c %a "$SB/etc/sudoers.d/10-devuser")"
  check "sudoers: visudo -cf passes" visudo -cqf "$SB/etc/sudoers.d/10-devuser"
  configure_sudoers devuser password
  check_eq "sudoers: password mode rule" "devuser ALL=(ALL:ALL) ALL" "$(sudo_rules)"
  check_eq "sudoers_mode_of reads the mode back" "password" "$(sudoers_mode_of devuser)"
  # rm first: the files are mode 0440, which only root may overwrite in place.
  rm -f "$SB/etc/sudoers"; printf 'root ALL=(ALL:ALL) ALL\n' >"$SB/etc/sudoers"
  configure_sudoers devuser nopasswd
  check "sudoers: @includedir appended to a main file that lacked it" grep -qx "@includedir $SB/etc/sudoers.d" "$SB/etc/sudoers"
  check "sudoers: main file still valid after the append" visudo -cqf "$SB/etc/sudoers"
  rm -f "$SB/etc/sudoers"; printf 'root ALL=(ALL:ALL) ALL\nthis is not sudoers syntax\n' >"$SB/etc/sudoers"
  before="$(sha256sum <"$SB/etc/sudoers")"
  configure_sudoers devuser nopasswd 2>/dev/null; rc=$?
  check "sudoers: invalid main file -> failure, file left unchanged (rollback)" test "$rc" -ne 0 -a "$before" == "$(sha256sum <"$SB/etc/sudoers")"
  rm -f "$SB/etc/sudoers.d/10-devuser"; printf 'devuser ALL=(ALL) ALL\n' >"$SB/etc/sudoers.d/10-devuser"
  remove_sudoers devuser 2>/dev/null
  check "remove_sudoers keeps a drop-in it does not manage" test -f "$SB/etc/sudoers.d/10-devuser"
else
  skip "visudo not installed (sudo package)"
fi
printf 'OMARCHY_HOME_DIRS="code notes/2026 ../evil /abs ok/./x .config"\n' >"$OMARCHY_USER_CONF"
check_eq "OMARCHY_HOME_DIRS whitelist (no absolute, no ..)" "code notes/2026" "$(user_conf_home_dirs 2>/dev/null | head -n 2 | tr '\n' ' ' | sed 's/ $//')"
check "OMARCHY_HOME_DIRS rejects ../evil, /abs, ok/./x" bash -c "! (source '$ACCOUNT_LIB'; user_conf_home_dirs 2>/dev/null) | grep -Eq '^(\\.\\./evil|/abs|ok/\\./x)$'"

# =============================================================================
header "OOBE CLI contract"
# =============================================================================
reset_sandbox
run_oobe --help
check "--help exits 0 with usage on stdout" bash -c "[[ $RC -eq 0 ]] && grep -q '^Usage: oobe.sh' '$OUT'"
run_oobe --version
check "--version exits 0" bash -c "[[ $RC -eq 0 ]] && grep -q '^omarchy-oobe ' '$OUT'"
run_oobe --bogus
check "unknown option exits 2 with usage on stderr" bash -c "[[ $RC -eq 2 ]] && grep -q 'Usage: oobe.sh' '$ERR' && [[ ! -s '$OUT' ]]"
run_oobe --user
check "--user without a value exits 2" test "$RC" -eq 2
run_oobe stray-arg
check "positional argument exits 2" test "$RC" -eq 2
if [[ "$(id -u)" -ne 0 ]]; then
  OMARCHY_ALLOW_NONROOT=0 bash "$OOBE" --headless --user devuser >"$OUT" 2>"$ERR" </dev/null; RC=$?
  check "non-root exits 3 with the wsl.exe -u root hint" bash -c "[[ $RC -eq 3 ]] && grep -q 'wsl.exe -d .* -u root -- /usr/lib/wsl/oobe.sh' '$ERR'"
elif id tester >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1; then
  setpriv --reuid="$(id -u tester)" --regid="$(id -g tester)" --clear-groups env OMARCHY_ALLOW_NONROOT=0 bash "$OOBE" --headless --user devuser >"$OUT" 2>"$ERR" </dev/null; RC=$?
  check "non-root exits 3 with the wsl.exe -u root hint" bash -c "[[ $RC -eq 3 ]] && grep -q 'wsl.exe -d .* -u root -- /usr/lib/wsl/oobe.sh' '$ERR'"
else
  skip "non-root check: no unprivileged user to switch to"
fi

# =============================================================================
header "OOBE headless provisioning (image build / CI contract)"
# =============================================================================
reset_sandbox
run_oobe --headless --user devuser
check "exit 0" test "$RC" -eq 0
check_eq "uid 1000 = devuser, own primary group gid 1000, /bin/bash" "devuser:x:1000:1000::$SB/home/devuser:/bin/bash" "$(pw_entry devuser)"
check "group devuser created with gid 1000 (groupadd -g 1000)" calls_has '^groupadd -g 1000 devuser$'
check "only existing groups added (wheel,docker,video,audio; no render/input)" calls_has '^usermod -aG wheel,docker,video,audio devuser$'
check_eq "home is 0700" "700" "$(stat -c %a "$SB/home/devuser")"
check "skel copied into the fresh home" test -f "$SB/home/devuser/.bashrc"
check "history purged from the fresh home" test ! -e "$SB/home/devuser/.bash_history"
check_eq "home holds only skel + .config/.local (no hard-coded workspace dirs)" ".bashrc .config .local" "$(find "$SB/home/devuser" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "scaffold dirs created as the owner (runuser)" calls_has "^runuser -u devuser -- env -i .* mkdir -p -- $SB/home/devuser/.local/bin$"
check "password locked (passwd -l), never emptied" bash -c "grep -q '^passwd -l devuser$' '$LOG/calls' && ! grep -q '^passwd -d' '$LOG/calls'"
check_eq "shadow entry locked" "!" "$(awk -F: '$1=="devuser"{print substr($2,1,1)}' "$SB/etc/shadow")"
if command -v visudo >/dev/null 2>&1; then
  check_eq "sudoers: ONLY 'devuser ALL=(ALL:ALL) NOPASSWD: ALL'" "devuser ALL=(ALL:ALL) NOPASSWD: ALL" "$(sudo_rules)"
  check "sudoers: no %wheel rule anywhere" bash -c "! grep -hv '^#' '$SB/etc/sudoers.d/'* | grep -q '%wheel'"
  check "sudoers: whole configuration passes visudo -c" visudo -cqf "$SB/etc/sudoers"
fi
check "linger marker written offline" test -f "$SB/var/lib/systemd/linger/devuser"
check "loginctl not called without systemd as PID 1" bash -c "! grep -q '^loginctl' '$LOG/calls'"
check_eq "wsl.conf [user] default = devuser" "devuser" "$(wsl_conf_default_user)"
check "wsl.conf: shipped sections preserved" bash -c "grep -q '^systemd = true' '$OMARCHY_WSL_CONF' && grep -q '^appendWindowsPath = false' '$OMARCHY_WSL_CONF'"
check_eq "sentinel: PROVISIONED_UID=1000 PROVISIONED_USER=devuser" "1000 devuser" "$(sentinel_get PROVISIONED_UID) $(sentinel_get PROVISIONED_USER)"
check "user.conf: DEFAULT_USER=devuser, OMARCHY_HOME_DIRS kept" bash -c "grep -qx 'DEFAULT_USER=devuser' '$OMARCHY_USER_CONF' && grep -qx 'OMARCHY_HOME_DIRS=\"\"' '$OMARCHY_USER_CONF'"
check "pacman keyring initializer invoked" calls_has '^pacman-init'
check "network sync tools NOT run without --sync-network" bash -c "! grep -q '^omarchy-.*-sync' '$LOG/calls'"
check "Omarchy helpers run as the owner with a clean environment" grep -q "^theme HOME=$SB/home/devuser USER=devuser BRIDGE=0 ARG=Tokyo Night$" "$LOG/env"
check "nvim setup ran as the owner" grep -q "^nvim HOME=$SB/home/devuser USER=devuser$" "$LOG/env"
check "cmd.exe not consulted when --user is given" bash -c "! grep -q '^cmd.exe' '$LOG/calls'"
check "no temp files left anywhere in the sandbox" test "$(find "$SB" -name '*.omw.*' | wc -l)" -eq 0

# Idempotency: a second run changes nothing and calls nothing.
h1="$(tree_hash)"; : >"$LOG/calls"
run_oobe --headless
check "re-run: exit 0" test "$RC" -eq 0
check "re-run: no external command executed" test ! -s "$LOG/calls"
check "re-run: sandbox byte-identical" test "$h1" == "$(tree_hash)"
run_oobe --headless --user bob
check "different --user while uid 1000 exists: exit 3, points to omarchy-rename-owner" \
  bash -c "[[ $RC -eq 3 ]] && grep -q 'omarchy-rename-owner bob' '$ERR'"
check "different --user: nothing renamed" test "$(owner)" == "devuser"

# Row 11: the owner was renamed outside the OOBE; config and sentinel still
# name the old account. The OOBE must not rename it back.
sed -i 's/^devuser:/jane:/' "$SB/etc/passwd" "$SB/etc/shadow"
: >"$LOG/calls"
run_oobe --headless
check "renamed owner + stale sentinel/user.conf: exit 0, no-op" bash -c "[[ $RC -eq 0 ]] && [[ ! -s '$LOG/calls' ]]"
check "renamed owner is NOT renamed back" test "$(owner)" == "jane"
check "stale sentinel name reported" grep -q "sentinel records 'devuser'" "$ERR"

# --force re-applies config, never touches the password or history.
printf 'precious\n' >"$SB/home/devuser/.bash_history"
sed -i 's/^jane:/devuser:/' "$SB/etc/passwd" "$SB/etc/shadow"
: >"$LOG/calls"
run_oobe --headless --force
check "--force: exit 0" test "$RC" -eq 0
check "--force: no useradd, no passwd change" bash -c "! grep -Eq '^(useradd|passwd|chpasswd)' '$LOG/calls'"
check "--force: existing history kept" test -f "$SB/home/devuser/.bash_history"
check "--force: sudoers rewritten (still owner-only)" test "$(sudo_rules)" == "devuser ALL=(ALL:ALL) NOPASSWD: ALL"

# =============================================================================
header "OOBE name selection, collisions and pre-existing uid 1000"
# =============================================================================
for bad in Root 9abc root "a b" "../x" "$(printf 'n%.0s' {1..32})" daemon; do
  reset_sandbox; run_oobe --headless --user "$bad"
  if [[ $RC -ne 2 ]]; then fail "invalid --user '$bad' exits 2 (got $RC)"; continue; fi
  if [[ -n "$(owner)" ]]; then fail "invalid --user '$bad' created an account"; continue; fi
  pass "invalid --user '${bad:0:12}' rejected strictly (exit 2, nothing created)"
done
reset_sandbox; printf 'bob:x:1001:1001::/home/bob:/bin/bash\n' >>"$SB/etc/passwd"
run_oobe --headless --user bob
check "--user naming another uid: exit 3" test "$RC" -eq 3
reset_sandbox; run_oobe --headless --user devs
check "--user colliding with an existing group (devs): exit 3" bash -c "[[ $RC -eq 3 ]] && grep -q \"group 'devs' already exists\" '$ERR'"
reset_sandbox; printf 'legacy:x:1000:\n' >>"$SB/etc/group"
run_oobe --headless --user devuser
check "gid 1000 taken by another group: owner gets the next free gid" bash -c "[[ $RC -eq 0 ]] && grep -q '^groupadd devuser$' '$LOG/calls' && grep -q 'gid 1000 is used by group' '$ERR'"
reset_sandbox; printf 'devuser:x:1000:\n' >>"$SB/etc/group"
run_oobe --headless --user devuser
check "existing gid-1000 group of the same name is reused" bash -c "[[ $RC -eq 0 ]] && ! grep -q '^groupadd' '$LOG/calls'"
reset_sandbox; mkdir -p "$SB/home/devuser"
run_oobe --headless --user devuser
if [[ "$(id -u)" -eq 1000 ]]; then
  check "pre-existing /home/devuser owned by uid 1000 is reused" test "$RC" -eq 0
else
  check "pre-existing /home/devuser owned by another uid: exit 3, no account" bash -c "[[ $RC -eq 3 ]] && [[ -z \"\$(awk -F: '\$3==1000' '$SB/etc/passwd')\" ]]"
fi

# Pre-existing, never provisioned uid 1000 (e.g. a stock 'alarm' account).
reset_sandbox
printf 'alarm:x:1000:1000::%s/home/alarm:/bin/bash\n' "$SB" >>"$SB/etc/passwd"
printf 'alarm:x:1000:\n' >>"$SB/etc/group"
printf 'alarm:$6$knownpassword:20000:0:99999:7:::\n' >>"$SB/etc/shadow"
mkdir -p "$SB/home/alarm"; printf 'keep\n' >"$SB/home/alarm/.bash_history"
run_oobe --headless --user devuser
check "existing uid 1000 + different --user: exit 3, no rename" bash -c "[[ $RC -eq 3 ]] && [[ \"\$(awk -F: '\$3==1000{print \$1}' '$SB/etc/passwd')\" == alarm ]]"
: >"$LOG/calls"
run_oobe --headless
check "existing unprovisioned uid 1000 is adopted (exit 0, not renamed)" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(awk -F: '\$3==1000{print \$1}' '$SB/etc/passwd')\" == alarm ]]"
check "adopt: no useradd/usermod -l/pkill" bash -c "! grep -Eq '^(useradd|usermod -l|pkill)' '$LOG/calls'"
check "adopt: the known stock password is locked" grep -q '^alarm:!' "$SB/etc/shadow"
check "adopt: existing history is kept (not a fresh home)" test -f "$SB/home/alarm/.bash_history"
check_eq "adopt: sentinel records alarm" "alarm" "$(sentinel_get PROVISIONED_USER)"

# Preseed and Windows-name detection (suggest mode).
reset_sandbox; printf 'DEFAULT_USER=preseeded\n' >"$OMARCHY_USER_CONF"
run_oobe --headless
check_eq "DEFAULT_USER preseed in /etc/omarchy-user.conf names the owner" "preseeded" "$(owner)"
reset_sandbox; printf 'DEFAULT_USER="Bad Name"\n' >"$OMARCHY_USER_CONF"
FAKE_WIN_USER="José Müller" run_oobe --headless
check_eq "invalid preseed ignored; detected Windows name used" "jose_muller" "$(owner)"
check "cmd.exe ran from the DrvFs cwd with /d /c" calls_has "^cmd.exe cwd=$MNT/c /d /c echo %USERNAME%$"
reset_sandbox; printf 'BOOT_IMAGE=/vmlinuz omarchy.user=Kernel.User quiet\n' >"$T/cmdline"
run_oobe --headless
check_eq "kernel command line omarchy.user= wins over interop" "kernel_user" "$(owner)"
reset_sandbox
WSLENV="USERNAME/u:PATH/l" USERNAME="Ünïcode" run_oobe --headless
check_eq "USERNAME forwarded through WSLENV" "unicode" "$(owner)"
reset_sandbox; mkdir -p "$MNT/c/Users/Zoë" "$MNT/c/Users/Public" "$MNT/c/Users/Default"
SSH_CONNECTION="10.0.0.9 5000 10.0.0.1 22" run_oobe
check_eq "over SSH: headless, cmd.exe skipped, the single Users profile used" "zoe" "$(owner)"
check "over SSH: cmd.exe not executed" bash -c "! grep -q '^cmd.exe' '$LOG/calls'"
reset_sandbox; mkdir -p "$MNT/c/Users/anna" "$MNT/c/Users/ben"
SSH_TTY=/dev/pts/9 run_oobe
check_eq "two Windows profiles and no interop: deterministic fallback" "omarchy" "$(owner)"
reset_sandbox; FAKE_WIN_USER="张伟" run_oobe --headless
check_eq "all-CJK Windows name: deterministic fallback" "omarchy" "$(owner)"
reset_sandbox; FAKE_WIN_USER="root" run_oobe --headless
check_eq "Windows name 'root' (reserved): u_ prefix suggested" "u_root" "$(owner)"

# =============================================================================
header "OOBE interactive prompts (fd 3/4 via OMARCHY_TTY_IN/_OUT)"
# =============================================================================
TTY_OUT="$T/tty.out"
reset_sandbox; : >"$TTY_OUT"
printf 'Bad Name\nalice\ns3cret\ns3cret\ny\n' >"$T/tty.in"
OMARCHY_TTY_IN="$T/tty.in" OMARCHY_TTY_OUT="$TTY_OUT" run_oobe
check "interactive: exit 0" test "$RC" -eq 0
check_eq "interactive: invalid name re-prompted, then 'alice' accepted" "alice" "$(owner)"
check "interactive: prompts go to the terminal, never to stdout" bash -c "[[ ! -s '$OUT' ]] && grep -q 'Linux user name \\[jane_doe\\]' '$TTY_OUT' && grep -q 'Not accepted' '$TTY_OUT'"
check_eq "interactive: password reached chpasswd on stdin (hash recorded)" "alice $(printf 's3cret' | sha256sum | cut -c1-16)" "$(cat "$LOG/chpasswd.stdin" 2>/dev/null)"
check "interactive: password never appears in argv logs" bash -c "! grep -rq 's3cret' '$LOG/calls'"
check_eq "interactive: 'y' -> sudo asks for the password" "alice ALL=(ALL:ALL) ALL" "$(sudo_rules)"
check "interactive: password set, so not locked" bash -c "! grep -q '^passwd -l' '$LOG/calls'"
reset_sandbox; : >"$TTY_OUT"
printf '\n\n' >"$T/tty.in"
OMARCHY_TTY_IN="$T/tty.in" OMARCHY_TTY_OUT="$TTY_OUT" run_oobe
check "interactive: empty answers -> suggested name, locked password, NOPASSWD" \
  bash -c "[[ \"\$(awk -F: '\$3==1000{print \$1}' '$SB/etc/passwd')\" == jane_doe ]] && grep -q '^passwd -l jane_doe$' '$LOG/calls'"
check_eq "interactive: empty password -> NOPASSWD rule" "jane_doe ALL=(ALL:ALL) NOPASSWD: ALL" "$(sudo_rules)"
reset_sandbox; : >"$TTY_OUT"
printf 'carol\n\na\nb\npw1\npw1\n' >"$T/tty.in"
OMARCHY_TTY_IN="$T/tty.in" OMARCHY_TTY_OUT="$TTY_OUT" run_oobe --require-password
check "--require-password interactive: empty and mismatched passwords re-asked" bash -c "grep -q 'A password is required' '$TTY_OUT' && grep -q 'do not match' '$TTY_OUT'"
check_eq "--require-password interactive: password rule, no sudo question" "carol ALL=(ALL:ALL) ALL" "$(sudo_rules)"
check "--require-password interactive: sudo question not asked" bash -c "! grep -q 'when using sudo' '$TTY_OUT'"
reset_sandbox
run_oobe --headless --user dave --require-password
check "--require-password headless: password rule + locked + hint to set one" \
  bash -c "[[ $RC -eq 0 ]] && grep -q 'passwd dave' '$ERR' && grep -q '^passwd -l dave$' '$LOG/calls'"
check_eq "--require-password headless: password-required rule (honoured, row 41)" "dave ALL=(ALL:ALL) ALL" "$(sudo_rules)"
reset_sandbox
printf 'fromstdin\n' | bash "$OOBE" --headless --user erin --password-stdin >"$OUT" 2>"$ERR"; RC=$?
check_eq "--password-stdin: password set via chpasswd stdin" "erin $(printf 'fromstdin' | sha256sum | cut -c1-16)" "$(cat "$LOG/chpasswd.stdin" 2>/dev/null)"
check_eq "--password-stdin without --require-password: NOPASSWD" "erin ALL=(ALL:ALL) NOPASSWD: ALL" "$(sudo_rules)"

if command -v script >/dev/null 2>&1; then
  reset_sandbox
  (sleep 1.5; printf 'ptyuser\n'; sleep 1.5; printf 'pwsecret9\n'; sleep 1; printf 'pwsecret9\n'; sleep 1; printf 'n\n'; sleep 1) \
    | OMARCHY_NO_TTY="" script -qec "bash '$OOBE'" /dev/null >"$T/pty.out" 2>&1
  check_eq "real pty: owner created from the /dev/tty answer" "ptyuser" "$(owner)"
  check "real pty: password not echoed to the terminal" bash -c "! grep -q 'pwsecret9' '$T/pty.out'"
  check_eq "real pty: 'n' -> NOPASSWD" "ptyuser ALL=(ALL:ALL) NOPASSWD: ALL" "$(sudo_rules)"
else
  skip "script(1) not installed: real-pty prompt test"
fi

# =============================================================================
header "OOBE signals, lock, bounded helpers, home dirs"
# =============================================================================
for sig in TERM:143 INT:130 HUP:129; do
  reset_sandbox
  set -m
  FAKE_PACMAN_SLEEP=20 FAKE_PACMAN_MARK="$T/pacman.mark" bash "$OOBE" --headless --user sig >"$OUT" 2>"$ERR" </dev/null &
  pid=$!
  set +m
  for _ in $(seq 1 100); do [[ -e "$T/pacman.mark" ]] && break; sleep 0.1; done
  kill -"${sig%%:*}" -- -"$pid" 2>/dev/null
  wait "$pid"; RC=$?
  rm -f "$T/pacman.mark"
  check "SIG${sig%%:*} during provisioning exits ${sig#*:} (never 0), no sentinel" \
    bash -c "[[ $RC -eq ${sig#*:} ]] && [[ ! -e '$OMARCHY_SENTINEL_DIR/oobe_completed' ]]"
done
check "interrupted run leaves no temp files" test "$(find "$SB" -name '*.omw.*' | wc -l)" -eq 0
if command -v flock >/dev/null 2>&1; then
  reset_sandbox; mkdir -p "$SB/run/omarchy"
  set -m; flock "$OMARCHY_LOCK_FILE" sleep 30 & lockpid=$!; set +m
  BG_PIDS+=("$lockpid")
  sleep 0.3
  run_oobe --headless --user lockme
  check "concurrent OOBE: exit 75 with a clear message, nothing created" \
    bash -c "[[ $RC -eq 75 ]] && grep -q 'Another OOBE' '$ERR' && [[ -z \"\$(awk -F: '\$3==1000' '$SB/etc/passwd')\" ]]"
  # flock's child (sleep) holds the lock too: kill the whole process group.
  kill -- -"$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null
else
  skip "flock not installed"
fi
reset_sandbox
start=$(date +%s)
FAKE_SYNC_SLEEP=30 OMARCHY_SYNC_TIMEOUT=1 run_oobe --headless --user syncer --sync-network
elapsed=$(( $(date +%s) - start ))
check "--sync-network: a hung omarchy-dns-sync is killed by its timeout" bash -c "[[ $RC -eq 0 ]] && (( $elapsed < 15 )) && grep -q 'omarchy-dns-sync failed or timed out' '$ERR'"
check "--sync-network: dns-sync gets 'sync', ca/proxy-sync run" bash -c "grep -q '^omarchy-dns-sync sync$' '$LOG/calls' && grep -q '^omarchy-ca-sync' '$LOG/calls' && grep -q '^omarchy-proxy-sync' '$LOG/calls'"
reset_sandbox
printf 'OMARCHY_HOME_DIRS="code notes/2026 ../evil"\n' >"$OMARCHY_USER_CONF"
run_oobe --headless --user dirs
check "OMARCHY_HOME_DIRS: listed dirs created in the home" bash -c "[[ -d '$SB/home/dirs/code' && -d '$SB/home/dirs/notes/2026' ]]"
check "OMARCHY_HOME_DIRS: traversal entry rejected" bash -c "[[ ! -e '$SB/home/evil' ]] && grep -q \"Ignoring OMARCHY_HOME_DIRS entry '../evil'\" '$ERR'"
reset_sandbox
OMARCHY_SYSTEMD_RUNNING=1 run_oobe --headless --user lingerer
check "under systemd: loginctl enable-linger is called (bounded)" calls_has '^loginctl enable-linger lingerer$'

# Windows tool shims: only with interop (binfmt WSLInterop[-late] enabled).
mkdir -p "$T/binfmt"
reset_sandbox; rm -f "$T/binfmt"/*
run_oobe --headless --user noshims
check "shims: skipped when binfmt WSLInterop is absent (container/image build)" \
  bash -c "[[ $RC -eq 0 ]] && ! grep -q '^wsl-shims-setup' '$LOG/calls' && grep -q 'skipping the Windows tool shims' '$ERR'"
reset_sandbox; printf 'disabled\ninterpreter /init\n' >"$T/binfmt/WSLInterop"
run_oobe --headless --user offshims
check "shims: skipped when WSLInterop is registered but disabled" bash -c "[[ $RC -eq 0 ]] && ! grep -q '^wsl-shims-setup' '$LOG/calls'"
reset_sandbox; rm -f "$T/binfmt"/*; printf 'enabled\ninterpreter /init\n' >"$T/binfmt/WSLInterop-late"
WSL_INTEROP=/run/WSL/42_interop run_oobe --headless --user shimmed
check "shims: run once when WSLInterop-late is enabled, after the account exists" \
  bash -c "[[ $RC -eq 0 ]] && [[ \$(grep -c '^wsl-shims-setup' '$LOG/calls') -eq 1 ]] && awk '/^useradd/{u=NR} /^wsl-shims-setup/{s=NR} END{exit !(u && s > u)}' '$LOG/calls'"
check "shims: the interop session (WSL_INTEROP) reaches the installer" grep -q '^shims WSL_INTEROP=/run/WSL/42_interop uid=' "$LOG/env"
reset_sandbox; printf 'enabled\n' >"$T/binfmt/WSLInterop-late"
start=$(date +%s)
FAKE_SHIMS_SLEEP=30 OMARCHY_SHIMS_TIMEOUT=1 run_oobe --headless --user slowshims
elapsed=$(( $(date +%s) - start ))
check "shims: a hung installer is killed by its timeout; OOBE still exits 0" \
  bash -c "[[ $RC -eq 0 ]] && (( $elapsed < 15 )) && grep -q 'failed or timed out' '$ERR' && grep -qx 'PROVISIONED_USER=slowshims' '$OMARCHY_SENTINEL_DIR/oobe_completed'"
reset_sandbox; printf 'enabled\n' >"$T/binfmt/WSLInterop"
FAKE_SHIMS_RC=7 run_oobe --headless --user badshims
check "shims: a failing installer is a warning, never the OOBE exit status" bash -c "[[ $RC -eq 0 ]] && grep -q 'failed or timed out' '$ERR'"
rm -f "$T/binfmt"/*

# /etc/omarchy-user.conf missing: seeded from the shipped template.
reset_sandbox; rm -f "$OMARCHY_USER_CONF"
OMARCHY_USER_CONF_TEMPLATE="$ROOT_DIR/wsl/omarchy-user.conf" run_oobe --headless --user seeded
check "user.conf seeded from the template (documented keys kept) + DEFAULT_USER" \
  bash -c "grep -qx 'DEFAULT_USER=seeded' '$OMARCHY_USER_CONF' && grep -qx 'OMARCHY_HOME_DIRS=\"\"' '$OMARCHY_USER_CONF' && grep -q '^# DEFAULT_USER' '$OMARCHY_USER_CONF'"

# =============================================================================
header "profile.d first-boot hook (non-root, POSIX)"
# =============================================================================
if [[ "$(id -u)" -ne 0 ]]; then
  check "hook is inert for non-root users" bash -c "out=\$(sh -c '. \"$HOOK\"; echo alive' 2>&1); [[ \$out == alive ]]"
fi
check "hook is inert for a non-interactive root shell" bash -c "out=\$(sh -c '. \"$HOOK\"; echo alive' </dev/null 2>&1); [[ \$out == alive ]]"
check "hook checks SUDO_USER and the parent process chain" bash -c "grep -q 'SUDO_USER' '$HOOK' && grep -q 'PPid' '$HOOK'"
check "hook keys the owner on uid 1000" grep -q 'getent passwd 1000' "$HOOK"

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
  for b in "$T2_SNAP"/%*; do
    [[ -f "$b" ]] || continue
    f="$(basename "$b" | tr % /)"
    cp -p "$b" "$f"
  done
  [[ -f "$T2_SNAP/%etc%wsl.conf" ]] || rm -f /etc/wsl.conf
  [[ -f "$T2_SNAP/%etc%omarchy-user.conf" ]] || rm -f /etc/omarchy-user.conf
  for f in /etc/sudoers.d/*; do
    grep -qx "$(basename "$f")" "$T2_SNAP/sudoers.d.list" || rm -f "$f"
  done
  for f in /home/devuser /home/ptyroot; do
    grep -qx "$(basename "$f")" "$T2_SNAP/home.list" || rm -rf "$f"
  done
  rm -rf /var/lib/omarchy /var/lib/systemd/linger/devuser /usr/lib/wsl/oobe.sh /usr/lib/omarchy-wsl/oobe.sh \
         /usr/lib/omarchy-wsl/account.sh /usr/lib/omarchy-wsl/common.sh /etc/profile.d/00-omarchy-firstboot.sh
  T2_SNAP=""
}

t2_oobe() {
  header "T2 real root: real useradd/visudo/runuser in a throwaway container"
  local o
  # Real tools only: without this, runuser/sudo checks would hit the stubs.
  local PATH="$REAL_PATH"
  t2_snapshot
  o="$(getent passwd 1000 | cut -d: -f1)"
  [[ -n "$o" ]] && userdel "$o" >/dev/null 2>&1
  install -d /usr/lib/wsl /usr/lib/omarchy-wsl
  install -m 0644 "$ACCOUNT_LIB" /usr/lib/omarchy-wsl/account.sh
  install -m 0644 "$COMMON_LIB" /usr/lib/omarchy-wsl/common.sh
  install -m 0755 "$OOBE" /usr/lib/wsl/oobe.sh
  ln -sfn /usr/lib/wsl/oobe.sh /usr/lib/omarchy-wsl/oobe.sh
  install -m 0644 "$HOOK" /etc/profile.d/00-omarchy-firstboot.sh
  local -a clean=(env -u OMARCHY_PASSWD_ROOT -u OMARCHY_SENTINEL_DIR -u OMARCHY_USER_CONF -u OMARCHY_WSL_CONF
    -u OMARCHY_SUDOERS_DIR -u OMARCHY_SUDOERS_MAIN -u OMARCHY_LINGER_DIR -u OMARCHY_HOME_ROOT -u OMARCHY_SKEL_DIR
    -u OMARCHY_LOCK_FILE -u OMARCHY_TENANT_ROOT -u OMARCHY_NO_TTY -u OMARCHY_SYSTEMD_RUNNING -u OMARCHY_ALLOW_NONROOT
    -u OMARCHY_NOW -u OMARCHY_SHIMS_SETUP -u OMARCHY_BINFMT_DIR -u OMARCHY_USER_CONF_TEMPLATE
    "PATH=$REAL_PATH" OMARCHY_PACMAN_INIT= OMARCHY_DRVFS_ROOTS=/nonexistent)

  # 1. wsl --import fallback: the profile.d hook in a real root login shell.
  if command -v script >/dev/null 2>&1; then
    (sleep 2; printf 'devuser\n'; sleep 2; printf '\n'; sleep 3; printf 'id -un; exit\n'; sleep 2) \
      | "${clean[@]}" script -qec "bash -li" /dev/null >"$T/hook.out" 2>&1
    check "T2 hook: root login shell ran the OOBE, then switched to the owner" grep -q '^devuser' <(tr -d '\r' <"$T/hook.out")
    check "T2 hook: owner created through the prompts" test "$(getent passwd 1000 | cut -d: -f1)" == devuser
    check "T2 hook: inert once the sentinel exists" bash -c "printf 'echo hook-inert; exit\n' | ${clean[*]@Q} script -qec 'bash -li' /dev/null | tr -d '\r' | grep -q '^hook-inert'"
    userdel devuser >/dev/null 2>&1; rm -rf /home/devuser /var/lib/omarchy /etc/sudoers.d/10-devuser /var/lib/systemd/linger/devuser
    groupdel devuser >/dev/null 2>&1 || true
  else
    fail "T2 hook: script(1) missing"
  fi

  # 2. The exact CI contract.
  "${clean[@]}" /usr/lib/wsl/oobe.sh --headless --user devuser </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2 CI: /usr/lib/wsl/oobe.sh --headless --user devuser exits 0" test "$RC" -eq 0
  check_eq "T2 CI: getent passwd 1000 = devuser" "devuser" "$(getent passwd 1000 | cut -d: -f1)"
  check_eq "T2 CI: /home/devuser 0700 devuser:devuser" "700 devuser:devuser" "$(stat -c '%a %U:%G' /home/devuser)"
  check "T2 CI: visudo -c accepts the whole sudo configuration" visudo -cq
  check_eq "T2 CI: /etc/sudoers.d/10-devuser holds only the owner rule" "devuser ALL=(ALL:ALL) NOPASSWD: ALL" "$(grep -v '^#' /etc/sudoers.d/10-devuser)"
  check_eq "T2 CI: sudoers drop-in mode 0440 root:root" "440 root:root" "$(stat -c '%a %U:%G' /etc/sudoers.d/10-devuser)"
  check "T2 CI: linger marker /var/lib/systemd/linger/devuser" test -f /var/lib/systemd/linger/devuser
  check "T2 CI: /etc/wsl.conf [user] default = devuser" grep -qx 'default = devuser' /etc/wsl.conf
  check "T2 CI: sentinel PROVISIONED_UID=1000 / devuser" bash -c "grep -qx PROVISIONED_UID=1000 /var/lib/omarchy/oobe_completed && grep -qx PROVISIONED_USER=devuser /var/lib/omarchy/oobe_completed"
  check "T2 CI: /etc/omarchy-user.conf DEFAULT_USER=devuser" grep -qx 'DEFAULT_USER=devuser' /etc/omarchy-user.conf
  check "T2 CI: password locked, not empty" bash -c "[[ \"\$(getent shadow devuser | cut -d: -f2)\" == '!'* ]]"
  check "T2 CI: passwordless sudo works for the owner" runuser -u devuser -- sudo -n true
  check "T2 CI: root can still switch to the owner" su - devuser -c true
  "${clean[@]}" /usr/lib/wsl/oobe.sh --headless </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2 CI: re-run is a no-op (exit 0)" bash -c "[[ $RC -eq 0 ]] && grep -q 'Already provisioned' '$ERR'"
  "${clean[@]}" /usr/lib/wsl/oobe.sh --headless --user other </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2 CI: other --user refused (exit 3), owner unchanged" bash -c "[[ $RC -eq 3 ]] && [[ \"\$(getent passwd 1000 | cut -d: -f1)\" == devuser ]]"
  "${clean[@]}" /usr/lib/omarchy-wsl/oobe.sh --headless --force </dev/null >"$OUT" 2>"$ERR"; RC=$?
  check "T2 CI: compat path /usr/lib/omarchy-wsl/oobe.sh --force works" test "$RC" -eq 0
  t2_restore
}

if [[ "${OMW_REAL_ROOT:-auto}" == "0" ]]; then
  :
elif [[ "$(id -u)" -eq 0 ]] && in_container; then
  t2_oobe
elif [[ "${OMW_STRICT:-}" == "1" ]]; then
  header "T2 real root"
  fail "T2 real-root tier required (OMW_STRICT=1) but not running as root inside a container"
else
  header "T2 real root"
  skip "T2 real-root tier: needs root inside a throwaway container"
fi

printf '\n'
echo "OOBE Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-}" == "1" ]]; then exit 1; fi
exit 0
