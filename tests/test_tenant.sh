#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: omarchy-tenant Test Suite (T1 stub tier)
# /tests/test_tenant.sh
# ==============================================================================
# Exercises bin/omarchy-tenant end to end without root, systemd or a kernel
# that can run containers. Every host command the tool uses to change state
# (systemd-nspawn, machinectl, systemctl, systemd-run, slirp4netns, truncate,
# mkfs.ext4, mount, umount, pacstrap, tar, sysctl, tailscale, tailscaled) and
# the read-only probes it relies on (df, du, findmnt, mountpoint) are argv
# recorders on PATH. ssh-keygen, flock and getent are the real ones. A fake
# /proc tree plays the container leader. Runs the same as root or not.
#
#   OMW_STRICT=1          a skipped check counts as a failure
#   OMW_UPDATE_GOLDENS=1  rewrite tests/fixtures/tenant/*.golden from this run
#   OMW_TEST_KEEP=1       keep the sandbox for inspection
#
# Not covered here (future work, see docs/MULTI-TENANT-ISOLATION.md): T2 boots
# a real tenant in a privileged systemd container and runs the isolation gate
# list; T3 is the manual checklist on real WSL (x64 + ARM64, NAT + mirrored).
# ==============================================================================

# Helpers are called indirectly through check(); shellcheck cannot see that.
# shellcheck disable=SC2317

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="$ROOT_DIR/bin/omarchy-tenant"
FIXTURES="$ROOT_DIR/tests/fixtures/tenant"
STRICT="${OMW_STRICT:-0}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  \e[32m[PASS]\e[0m $*"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  \e[31m[FAIL]\e[0m $*"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); echo -e "  \e[33m[SKIP]\e[0m $*"; }
header() { echo -e "\n\e[1m\e[36m>>> TEST SUITE: $*\e[0m"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck || true)}"

# -----------------------------------------------------------------------------
# Sandbox
# -----------------------------------------------------------------------------
T=$(mktemp -d "${TMPDIR:-/tmp}/omw-tenant-test.XXXXXX")
BG_PIDS=()
cleanup() {
  local p
  for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
  if [[ -n "${OMW_TEST_KEEP:-}" ]]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

FAKEBIN="$T/fakebin"
LOG="$T/log"
STATE="$T/state"
ROOTD="$STATE/tenants"
UNITD="$STATE/units"
NSPD="$STATE/nspawn"
RUND="$STATE/run"
SYSD="$STATE/sysctl"
FPROC="$T/proc"
KEYS="$T/keys"
mkdir -p "$FAKEBIN" "$LOG" "$STATE" "$KEYS" "$T/tmp" "$T/dev/net" "$T/sys/fs/cgroup" \
         "$FPROC/4242/ns" "$FPROC/net" "$FPROC/sys/user" "$FPROC/sys/kernel"

# Fake container leader: private user namespace, seccomp + no_new_privs on,
# its own network namespace.
printf '         0 1879048192      65536\n' >"$FPROC/4242/uid_map"
printf 'Name:\tsystemd\nNoNewPrivs:\t1\nSeccomp:\t2\n' >"$FPROC/4242/status"
ln -s 'net:[4026532999]' "$FPROC/4242/ns/net"
# Host default route via 172.16.0.1 (little-endian hex) and a WSL-style resolver.
printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\neth0\t00000000\t010010AC\t0003\t0\t0\t0\t00000000\t0\t0\t0\n' >"$FPROC/net/route"
printf '63000\n' >"$FPROC/sys/user/max_user_namespaces"
printf '0\n' >"$FPROC/sys/kernel/io_uring_disabled"
printf 'nameserver 10.255.255.254\n' >"$T/resolv.conf"
: >"$T/dev/net/tun"
: >"$T/dev/loop-control"
: >"$T/sys/fs/cgroup/cgroup.controllers"

# --- Recorder stubs ------------------------------------------------------------
cat >"$FAKEBIN/.stublib" <<EOF
STUB_NAME="\${0##*/}"
{ printf '%s' "\$STUB_NAME"; printf ' %q' "\$@"; printf '\n'; } | tee -a "$T/all-argv.log" >>"$LOG/argv.log"
EOF

make_stub() {
  local name="$1" body="${2:-}"
  printf '#!/usr/bin/env bash\n. "${0%%/*}/.stublib"\n%s\nexit 0\n' "$body" >"$FAKEBIN/$name"
  chmod +x "$FAKEBIN/$name"
}

make_stub systemd-nspawn
make_stub mkfs.ext4
make_stub mount
make_stub umount
make_stub sysctl
make_stub tailscale
make_stub tailscaled
make_stub mountpoint 'exit "${FAKE_MOUNTPOINT_RC:-0}"'
make_stub findmnt 'echo "${FAKE_FSTYPE:-ext4}"'
make_stub df 'printf "    Avail\n%s\n" "${FAKE_DF_AVAIL:-10995116277760}"'
make_stub du 'printf "%s\t%s\n" "${FAKE_DU_BYTES:-0}" "${@: -1}"'
make_stub truncate ': >"${@: -1}"'
make_stub machinectl '[[ "$*" == *"-p Leader --value"* && -z "${FAKE_NO_LEADER:-}" ]] && echo "${FAKE_LEADER:-4242}"'
make_stub systemctl '
case "${1:-}" in
  is-active) s="${FAKE_ACTIVE:-active}"; echo "$s"; [[ "$s" == active ]] && exit 0; exit 3 ;;
  start) exit "${FAKE_START_RC:-0}" ;;
esac'
# Rootfs builders leave the binaries the tool checks for (unless told not to);
# FAKE_EVIL_ETC makes the "image" redirect /etc onto a host directory.
ROOTFS_BODY='
populate() {
  local d="$1"
  [[ -n "${FAKE_SLEEP_IN:-}" && "$FAKE_SLEEP_IN" == "${0##*/}" ]] && sleep "${FAKE_SLEEP_SECS:-3}"
  [[ -n "${FAKE_ROOTFS_EMPTY:-}" ]] && return 0
  mkdir -p "$d/usr/bin"
  : >"$d/usr/bin/sshd"
  : >"$d/usr/bin/tailscaled"
  [[ -n "${FAKE_EVIL_ETC:-}" ]] && ln -s "$FAKE_EVIL_ETC" "$d/etc"
  return 0
}'
make_stub pacstrap "$ROOTFS_BODY"'
for a in "$@"; do [[ "$a" == -* ]] && continue; populate "$a"; break; done'
make_stub tar "$ROOTFS_BODY"'
prev=""; for a in "$@"; do [[ "$prev" == -C ]] && populate "$a"; prev="$a"; done'
make_stub slirp4netns '
args=("$@"); pid="${args[${#args[@]}-2]}"
if [[ -z "${FAKE_SLIRP_NO_TAP:-}" ]]; then
  mkdir -p "$OMARCHY_TENANT_PROC/$pid/net"
  printf "Inter-|   Receive\n  tap0: 0 0 0 0\n" >"$OMARCHY_TENANT_PROC/$pid/net/dev"
fi'
make_stub systemd-run '
n=$(( $(ls "'"$LOG"'"/systemd-run.stdin.* 2>/dev/null | wc -l) + 1 ))
[[ -t 0 ]] || cat >"'"$LOG"'/systemd-run.stdin.$n"
case "$*" in
  *" -- /bin/true") exit "${FAKE_READY_RC:-0}" ;;
  *"done:probe"*)
    case "${FAKE_PROBE:-ok}" in
      ok) printf "ok:path:/mnt/c\nok:net:10.0.2.2:22\ndone:probe\n" ;;
      leak) printf "leak:path:/mnt/c\nok:net:10.0.2.2:22\ndone:probe\n" ;;
      netleak) printf "ok:path:/mnt/c\nleak:net:172.16.0.1:53\ndone:probe\n" ;;
      broken) exit 1 ;;
    esac ;;
  *"tailscale status --json"*) [[ -n "${FAKE_TS_STATUS:-}" ]] && cat "$FAKE_TS_STATUS" ;;
  *"tailscale up"*) exit "${FAKE_TS_UP_RC:-0}" ;;
esac'

export PATH="$FAKEBIN:$PATH"
export TMPDIR="$T/tmp" NO_COLOR=1
export OMARCHY_ALLOW_NONROOT=1 OMARCHY_SYSTEMD_RUNNING=1
export OMARCHY_TENANT_UNIT_DIR="$UNITD" OMARCHY_TENANT_NSPAWN_DIR="$NSPD" OMARCHY_TENANT_RUN_DIR="$RUND"
export OMARCHY_TENANT_SYSCTL_DIR="$SYSD" OMARCHY_TENANT_PROC="$FPROC" OMARCHY_TENANT_DEV="$T/dev"
export OMARCHY_TENANT_SYSFS="$T/sys" OMARCHY_TENANT_HOST_RESOLV="$T/resolv.conf"
export OMARCHY_TENANT_NOW=2026-01-01T00:00:00Z OMARCHY_TENANT_WAIT_SECS=1
unset OMARCHY_TENANT_EUID OMARCHY_WSL_LIB_DIR OMARCHY_TENANT_DATA_DIR OMARCHY_TENANT_DEBUG OMW_QUIET \
      SOURCE_DATE_EPOCH FAKE_ACTIVE FAKE_PROBE FAKE_TS_STATUS

R=(--root "$ROOTD")
G=$((1024 * 1024 * 1024))

# --- Helpers -------------------------------------------------------------------
RC=0 OUT=""
run() {
  "$TOOL" "$@" >"$T/out" 2>"$T/err" </dev/null
  RC=$?
  OUT="$(cat "$T/out")"
}
run_in() {
  local input="$1"
  shift
  "$TOOL" "$@" >"$T/out" 2>"$T/err" <"$input"
  RC=$?
  OUT="$(cat "$T/out")"
}
expect_rc() {
  local desc="$1" want="$2"
  if [[ "$RC" == "$want" ]]; then
    pass "$desc (exit $want)"
  else
    fail "$desc (want exit $want, got $RC)"
    printf '      stderr: %s\n' "$(head -n 4 "$T/err" | tr '\n' '|')"
  fi
}
reset_logs() { rm -f "$LOG"/*; }
# hold_lock <file>: a background process that holds flock(1) on <file> until
# killed (it execs into sleep, so killing $HOLDER releases the lock).
HOLDER=""
hold_lock() {
  local i
  ( exec 8>>"$1"; flock 8; exec sleep 60 ) &
  HOLDER=$!
  BG_PIDS+=("$HOLDER")
  for (( i = 0; i < 50; i++ )); do
    flock -n "$1" true 2>/dev/null || return 0
    sleep 0.1
  done
}
argv_log() { cat "$LOG/argv.log" 2>/dev/null; }
argv_has() { grep -qF -- "$1" "$LOG/argv.log" 2>/dev/null; }
argv_lacks() { ! grep -qF -- "$1" "$LOG/argv.log" 2>/dev/null; }
argv_empty() { [[ ! -s "$LOG/argv.log" ]]; }
out_has() { grep -qF -- "$1" "$T/out"; }
err_has() { grep -qF -- "$1" "$T/err"; }
err_lacks() { ! grep -qF -- "$1" "$T/err"; }
tmp_clean() { [[ -z "$(ls -A "$T/tmp")" ]]; }
# Commands that change state (everything but the read-only probes).
mutating_argv() { grep -vE '^(df|du|findmnt|mountpoint) ' "$LOG/argv.log" 2>/dev/null; }
# Deterministic listing (path, type, mode, sha256) of the state tree.
snapshot() {
  (
    cd "$STATE" || exit 1
    find . -printf '%p %y %m\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}
conf_get() { grep -E "^$2=" "$ROOTD/$1/tenant.conf" | tail -n 1 | cut -d= -f2-; }
# First word (plus systemctl/systemd-run verb) of every mutating command.
argv_verbs() {
  mutating_argv | awk '
    $1 == "systemctl" { if ($2 ~ /^--root=/) print "systemctl --root"; else print "systemctl " $2; next }
    $1 == "systemd-run" { if ($0 ~ /done:probe/) print "systemd-run probe"; else if ($0 ~ / -- \/bin\/true$/) print "systemd-run ready"; else print "systemd-run"; next }
    $1 == "machinectl" { next }
    { print $1 }'
}

# --- Keys ----------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -C 'alice@laptop' -f "$KEYS/ed" >/dev/null
ssh-keygen -q -t rsa -b 2048 -N '' -C 'old@rsa' -f "$KEYS/rsa2048" >/dev/null
ssh-keygen -q -t rsa -b 3072 -N '' -C 'bob@desk' -f "$KEYS/rsa3072" >/dev/null
ssh-keygen -q -t ecdsa -b 256 -N '' -C 'jane@tablet' -f "$KEYS/ecdsa" >/dev/null
ED_B64="$(awk '{print $2}' "$KEYS/ed.pub")"
RSA_B64="$(awk '{print $2}' "$KEYS/rsa3072.pub")"
EC_B64="$(awk '{print $2}' "$KEYS/ecdsa.pub")"
PRIV_LINE="$(sed -n 2p "$KEYS/ed")"
RSA_FPR="$(ssh-keygen -l -E sha256 -f "$KEYS/rsa3072.pub" | awk '{print $2}')"
printf 'command="/bin/date" %s\n' "$(cat "$KEYS/ed.pub")" >"$KEYS/opt.pub"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAnot-a-key\n' >"$KEYS/garbage.pub"
# Fake auth keys are assembled at run time so the repository never holds a
# literal that looks like a Tailscale key (secret scanners would flag it).
TSKEY_PREFIX="tskey"
FAKE_FILE_KEY="${TSKEY_PREFIX}-auth-kSECRETk-abc123XYZ"
FAKE_ARGV_KEY="${TSKEY_PREFIX}-auth-SECRETVALUE123"
printf '%s\n' "$FAKE_FILE_KEY" >"$T/authkey"
printf 'not-a-key\n' >"$T/badkey"
cat >"$T/ts-needs-login.json" <<'EOF'
{
  "Version": "1.76.1",
  "BackendState": "NeedsLogin",
  "AuthURL": "https://login.tailscale.com/a/abc123def",
  "TailscaleIPs": null,
  "Self": {
    "ID": "",
    "TailscaleIPs": null
  }
}
EOF
cat >"$T/ts-running.json" <<'EOF'
{
  "Version": "1.76.1",
  "BackendState": "Running",
  "AuthURL": "",
  "TailscaleIPs": [
    "100.101.102.103",
    "fd7a:115c:a1e0::1"
  ],
  "Self": {
    "TailscaleIPs": [
      "100.101.102.103"
    ]
  }
}
EOF

# =============================================================================
# 0. Static analysis and shipped templates
# =============================================================================
test_static() {
  header "Static analysis & templates"
  if [[ -n "$SHELLCHECK" ]]; then
    check "shellcheck -x bin/omarchy-tenant" "$SHELLCHECK" -x "$TOOL"
    check "shellcheck -x tests/test_tenant.sh" "$SHELLCHECK" -x "$SCRIPT_DIR/test_tenant.sh"
  else
    skip "shellcheck not installed"
  fi
  check "bash -n bin/omarchy-tenant" bash -n "$TOOL"
  local sshd="$ROOT_DIR/wsl/tenant/sshd_config" line bad=0
  for line in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'AuthenticationMethods publickey' \
              'PubkeyAuthentication yes' 'PermitRootLogin no' 'AllowTcpForwarding no' 'AllowStreamLocalForwarding no' \
              'AllowAgentForwarding no' 'X11Forwarding no' 'PermitTunnel no' 'GatewayPorts no' \
              'PermitUserEnvironment no' 'ListenAddress 127.0.0.1' 'ListenAddress ::1' \
              'AuthorizedKeysFile /etc/omarchy-tenant/authorized_keys' 'AllowUsers @TENANT@'; do
    grep -qxF "$line" "$sshd" || { bad=1; echo "      sshd_config lacks: $line"; }
  done
  check "sshd template is key-only, loopback-only, no forwarding" test "$bad" -eq 0
  check "sshd template has no ListenAddress 0.0.0.0" bash -c "! grep -qE '^ListenAddress (0\.0\.0\.0|::)\$' '$sshd'"
  check "tailscaled drop-in resets ExecStart to userspace networking" \
    bash -c "grep -qx 'ExecStart=' '$ROOT_DIR/wsl/tenant/tailscaled.conf' && grep -q -- '--tun=userspace-networking' '$ROOT_DIR/wsl/tenant/tailscaled.conf'"
  check "sysusers/tmpfiles templates create the tenant user with a 0700 home" \
    bash -c "grep -q '^u @TENANT@ ' '$ROOT_DIR/wsl/tenant/sysusers.conf' && grep -q '^d /home/@TENANT@ 0700 @TENANT@ @TENANT@' '$ROOT_DIR/wsl/tenant/tmpfiles.conf'"
  check "tool never writes .wslconfig, wsl.conf or the registry (code lines)" \
    bash -c "! grep -vE '^[[:space:]]*#' '$TOOL' | grep -qE '\.wslconfig|/etc/wsl\.conf|reg\.exe|powershell'"
  check "tool never uses rm -rf" bash -c "! grep -vE '^[[:space:]]*#' '$TOOL' | grep -qE 'rm -[a-zA-Z]*r[a-zA-Z]*f|rm -[a-zA-Z]*f[a-zA-Z]*r'"
  check "tool never sources tenant.conf" bash -c "! grep -nE '(source|\.)[[:space:]]+[^[:space:]]*tenant\.conf' '$TOOL'"
  check "tailscale is never told to advertise routes or act as exit node" bash -c "! grep -qE -- '--advertise|--exit-node' '$TOOL'"
}

# =============================================================================
# 1. CLI contract
# =============================================================================
test_cli() {
  header "CLI contract"
  run --help
  expect_rc "--help" 0
  check "--help prints usage on stdout" out_has "Usage: omarchy-tenant"
  run --version
  expect_rc "--version" 0
  check "--version prints the version" test "$OUT" = "omarchy-tenant 1.0.0"
  run
  expect_rc "no command" 2
  run frobnicate
  expect_rc "unknown command" 2
  run --frobnicate
  expect_rc "unknown global option" 2
  check "usage errors print usage on stderr only" bash -c "grep -q 'Usage: omarchy-tenant' '$T/err' && [[ ! -s '$T/out' ]]"
  run "${R[@]}" create
  expect_rc "create without a name" 2
  local args
  for args in "--size 20X" "--size 512M" "--mem 64M" "--mem lots" "--cpus 0" "--cpus 300" "--tasks 8" \
              "--tasks 100000" "--dns 10.1.2.3" "--dns 192.0.0.1" "--dns bogus" "--dns 1.1.1.1,8.8.8.8,9.9.9.9,1.0.0.1" \
              "--key x --key-stdin" "--bootstrap --image /x" "--size" "--frob"; do
    # shellcheck disable=SC2086
    run "${R[@]}" create alice $args
    expect_rc "create alice $args" 2
  done
  run "${R[@]}" key
  expect_rc "key without arguments" 2
  run "${R[@]}" key alice frob
  expect_rc "key with an unknown subcommand" 2
  run "${R[@]}" key alice remove not-a-fingerprint
  expect_rc "key remove with a malformed fingerprint" 2
  run "${R[@]}" status --bogus
  expect_rc "status with an unknown option" 2
  run "${R[@]}" auth-url alice --timeout 0
  expect_rc "auth-url --timeout 0" 2
  run --root relative/path list
  expect_rc "--root must be absolute" 2
  run --root / list
  expect_rc "--root / refused" 3
  run --root /mnt/c/tenants list
  expect_rc "--root on a Windows drive refused" 3
  check "nothing was executed by usage errors" argv_empty
}

# =============================================================================
# 2. Root requirement
# =============================================================================
test_root() {
  header "Root requirement"
  reset_logs
  local before after sub
  before="$(snapshot)"
  for sub in "create alice" "destroy alice --yes" "key alice add -" "start alice" "auth-url alice"; do
    # shellcheck disable=SC2086
    OMARCHY_ALLOW_NONROOT='' OMARCHY_TENANT_EUID=1000 run "${R[@]}" $sub
    expect_rc "$sub as non-root" 3
  done
  check "root hint names sudo" err_has "sudo omarchy-tenant"
  check "root hint names wsl.exe -u root" err_has "-u root -- omarchy-tenant"
  OMARCHY_ALLOW_NONROOT='' OMARCHY_TENANT_EUID=1000 run "${R[@]}" -n create alice
  expect_rc "--dry-run works without root" 0
  after="$(snapshot)"
  check "non-root attempts changed nothing" test "$before" = "$after"
  check "non-root attempts executed nothing mutating" bash -c "[[ -z \"\$(grep -vE '^(df|du|findmnt|mountpoint) ' '$LOG/argv.log' 2>/dev/null)\" ]]"
}

# =============================================================================
# 3. Names and path traversal (all exit 3; a missing name is exit 2)
# =============================================================================
test_names() {
  header "Tenant names & path traversal"
  reset_logs
  local before after n long
  long="$(printf 'a%.0s' {1..40})"
  before="$(snapshot)"
  for n in '../x' 'a b' 'Root' "$long" '-x' 'x-' '' 'root' 'daemon' 'users' '9lives' 'a_b' 'a/b' '.hidden' \
           'localhost' 'omarchy' 'tenants' $'a\nb'; do
    run "${R[@]}" create -- "$n"
    expect_rc "create $(printf '%q' "$n")" 3
  done
  check "31-character names are accepted by the syntax check" bash -c "'$TOOL' --root '$ROOTD' -n create '$(printf 'b%.0s' {1..31})' >/dev/null 2>&1"
  run "${R[@]}" -n create "$(printf 'b%.0s' {1..32})"
  expect_rc "32-character name" 3
  run "${R[@]}" destroy ../x --yes
  expect_rc "destroy ../x" 3
  run "${R[@]}" key ../x list
  expect_rc "key ../x list" 3
  after="$(snapshot)"
  check "rejected names created nothing" test "$before" = "$after"
  check "rejected names executed nothing mutating" bash -c "[[ -z \"\$(grep -vE '^(df|du|findmnt|mountpoint) ' '$LOG/argv.log' 2>/dev/null)\" ]]"
}

# =============================================================================
# 4. --dry-run
# =============================================================================
test_dry_run() {
  header "--dry-run renders everything and changes nothing"
  reset_logs
  local before after
  before="$(snapshot)"
  run "${R[@]}" create alice --dry-run --key "$KEYS/ed.pub"
  expect_rc "create alice --dry-run" 0
  check "prints the rendered unit" out_has "# ---- BEGIN $UNITD/omarchy-tenant-alice.service (0644) ----"
  check "unit text includes the nspawn command line" out_has "ExecStart=/usr/bin/systemd-nspawn --quiet --keep-unit --register=yes --boot --link-journal=no --settings=override --machine=alice --image=$ROOTD/alice/disk.raw"
  check "prints the rendered .nspawn" out_has "# ---- BEGIN $NSPD/alice.nspawn (0644) ----"
  check ".nspawn text includes PrivateUsers=pick" out_has "PrivateUsers=pick"
  check "prints tenant.conf" out_has "# ---- BEGIN $ROOTD/alice/tenant.conf (0600) ----"
  check "tenant.conf text names the tenant" out_has "name=alice"
  check "lists the sparse disk command" out_has "[dry-run] truncate -s 20G $ROOTD/alice/disk.raw"
  check "lists mkfs.ext4" out_has "[dry-run] mkfs.ext4 -q -F -L alice $ROOTD/alice/disk.raw"
  check "lists the bootstrap" out_has "[dry-run] pacstrap -c -K $RUND/alice/mnt base openssh tailscale"
  check "lists daemon-reload" out_has "[dry-run] systemctl daemon-reload"
  check "lists the start" out_has "[dry-run] systemctl start omarchy-tenant-alice.service"
  check "does not print key material" bash -c "! grep -qF '$ED_B64' '$T/out'"
  after="$(snapshot)"
  check "state tree is sha256-identical (no mkdir, no lock file)" test "$before" = "$after"
  check "no mutating command was executed" bash -c "[[ -z \"\$(grep -vE '^(df|du|findmnt|mountpoint) ' '$LOG/argv.log' 2>/dev/null)\" ]]"
  check "no temporary files left behind" tmp_clean
  run -n "${R[@]}" create bob --size 5G
  expect_rc "global -n before the command" 0
  run "${R[@]}" --dry-run destroy alice
  expect_rc "destroy --dry-run of a missing tenant" 5
  after="$(snapshot)"
  check "state tree still identical" test "$before" = "$after"
}

# =============================================================================
# 5. create (stub tier), goldens, systemd-analyze verify
# =============================================================================
golden() {
  # golden <rendered file> <golden name>
  local file="$1" name="$2" g="$FIXTURES/$2"
  if [[ -n "${OMW_UPDATE_GOLDENS:-}" ]]; then
    mkdir -p "$FIXTURES"
    sed "s#$ROOTD#@ROOT@#g" "$file" >"$g"
    pass "golden $name updated"
    return
  fi
  if [[ ! -f "$g" ]]; then
    fail "golden $name missing (run with OMW_UPDATE_GOLDENS=1)"
    return
  fi
  if diff -u "$g" <(sed "s#$ROOTD#@ROOT@#g" "$file") >"$T/golden.diff"; then
    pass "golden $name matches"
  else
    fail "golden $name differs"
    head -n 20 "$T/golden.diff" | sed 's/^/      /'
  fi
}

test_create() {
  header "create (journaled steps, rendered files, in-tenant files)"
  reset_logs
  run "${R[@]}" create alice --key "$KEYS/ed.pub"
  expect_rc "create alice" 0
  local unit="$UNITD/omarchy-tenant-alice.service" nsp="$NSPD/alice.nspawn" mnt="$RUND/alice/mnt"
  check "unit written" test -f "$unit"
  check ".nspawn written" test -f "$nsp"
  check "tenant.conf is 0600" test "$(stat -c %a "$ROOTD/alice/tenant.conf")" = 600
  check "host authorized_keys is 0600" test "$(stat -c %a "$ROOTD/alice/authorized_keys")" = 600
  check "state dir is 0700" test "$(stat -c %a "$ROOTD/alice")" = 700
  check "host authorized_keys holds the ed25519 key" grep -qF "$ED_B64" "$ROOTD/alice/authorized_keys"
  check "tenant.conf state=ready" test "$(conf_get alice state)" = ready
  check "journal records every step" test "$(tr '\n' ' ' <"$ROOTD/alice/journal")" = "conf keys disk rootfs units ready "
  golden "$unit" omarchy-tenant-alice.service.golden
  golden "$nsp" alice.nspawn.golden
  golden "$ROOTD/alice/tenant.conf" tenant.conf.golden
  local want got
  want="truncate mkfs.ext4 mount pacstrap systemctl --root umount systemctl daemon-reload systemctl enable systemctl start systemd-run ready systemd-run probe"
  got="$(argv_verbs | tr '\n' ' ')"
  check "commands run in order: $want" test "$got" = "$want "
  [[ "$got" == "$want " ]] || echo "      got: $got"
  check "mkfs.ext4 targets the tenant image" argv_has "mkfs.ext4 -q -F -L alice $ROOTD/alice/disk.raw"
  check "image mounted loop,nosuid,nodev on the private mount point" \
    bash -c "grep -E '^mount -o ' '$LOG/argv.log' | grep -F 'nosuid' | grep -F 'nodev' | grep -qF '$ROOTD/alice/disk.raw $mnt'"
  check "sshd and tailscaled enabled inside the image" argv_has "systemctl --root=$mnt enable sshd.service tailscaled.service"
  check "no host sysctl without --harden-host-io-uring" argv_lacks "sysctl"
  check "host tailscale/tailscaled never invoked" bash -c "! grep -qE '^(tailscale|tailscaled) ' '$LOG/argv.log'"
  check "in-tenant sshd_config names the tenant user" grep -qx 'AllowUsers alice' "$mnt/etc/ssh/sshd_config"
  check "in-tenant sshd_config has no template markers" bash -c "! grep -q '@TENANT@' '$mnt/etc/ssh/sshd_config'"
  check "in-tenant tailscaled drop-in installed" grep -q -- '--tun=userspace-networking' "$mnt/etc/systemd/system/tailscaled.service.d/10-omarchy-tenant.conf"
  check "in-tenant sysusers creates alice" grep -q '^u alice ' "$mnt/etc/sysusers.d/omarchy-tenant.conf"
  check "in-tenant resolv.conf uses the default public resolvers" bash -c "grep -qx 'nameserver 1.1.1.1' '$mnt/etc/resolv.conf' && grep -qx 'nameserver 9.9.9.9' '$mnt/etc/resolv.conf'"
  check "in-tenant hostname" test "$(cat "$mnt/etc/hostname")" = alice
  check "in-tenant authorized_keys holds the key" grep -qF "$ED_B64" "$mnt/etc/omarchy-tenant/authorized_keys"
  check "self-check passed" err_has "Isolation self-check passed for 'alice'"
  check "probe targets include the host resolver and the WSL gateway" \
    bash -c "grep 'done:probe' '$LOG/argv.log' | grep -qF '10.255.255.254 53 172.16.0.1 53'"
  check "probe targets include slirp's host alias and the metadata address" \
    bash -c "grep 'done:probe' '$LOG/argv.log' | grep -qF 'sh 10.0.2.2 22 10.0.2.2 80 169.254.169.254 80'"
  check "no temporary files left behind" tmp_clean
}

test_unit_verify() {
  header "systemd-analyze verify (rendered unit)"
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    skip "systemd-analyze not installed"
    return
  fi
  local v="$T/verify" out rc=0
  mkdir -p "$v"
  # The nspawn and omarchy-tenant binaries do not exist in the test container:
  # point ExecStart*/ at /bin/true and verify every other directive.
  sed -e 's#^ExecStart=/usr/bin/systemd-nspawn #ExecStart=/bin/true #' \
      -e 's#^ExecStartPost=/usr/bin/omarchy-tenant #ExecStartPost=/bin/true #' \
      "$UNITD/omarchy-tenant-alice.service" >"$v/omarchy-tenant-alice.service"
  out="$(systemd-analyze verify --man=no "$v/omarchy-tenant-alice.service" 2>&1)" || rc=$?
  check "systemd-analyze verify exits 0" test "$rc" -eq 0
  check "no unknown, invalid or ignored directives" bash -c "! grep -qiE 'unknown|invalid|failed|ignoring|not executable' <<<\"\$1\"" _ "$out"
  [[ -n "$out" ]] && printf '      %s\n' "$out" | head -n 10
  return 0
}

# =============================================================================
# 6. Idempotency, settings drift, re-render
# =============================================================================
test_idempotent() {
  header "create is idempotent"
  reset_logs
  run "${R[@]}" create alice --key "$KEYS/ed.pub"
  expect_rc "second create alice" 0
  check "second create executed no command at all" argv_empty
  check "second create says it already exists" err_has "already exists"
  run "${R[@]}" -n create alice
  expect_rc "dry-run of an existing tenant" 0
  check "dry-run of an existing tenant executed nothing" argv_empty
  run "${R[@]}" create alice --mem 8G
  expect_rc "create alice --mem 8G (different settings)" 3
  run "${R[@]}" create alice --key "$KEYS/rsa3072.pub"
  expect_rc "create alice with a new key (use key add)" 3
  run -q "${R[@]}" create alice
  expect_rc "create alice --quiet" 0
  check "--quiet silences informational logs" test ! -s "$T/err"
  printf '# local edit\n' >>"$UNITD/omarchy-tenant-alice.service"
  reset_logs
  run "${R[@]}" create alice
  expect_rc "create alice after a manual unit edit" 0
  golden "$UNITD/omarchy-tenant-alice.service" omarchy-tenant-alice.service.golden
  check "re-render reloads systemd" argv_has "systemctl daemon-reload"
  check "re-render never touches the disk" bash -c "! grep -qE '^(truncate|mkfs.ext4|pacstrap|mount) ' '$LOG/argv.log'"
}

# =============================================================================
# 7. Disk preflight, busy lock, missing dependencies, --image, rootfs checks
# =============================================================================
test_preconditions() {
  header "Preconditions: overcommit, busy lock, dependencies, image content"
  reset_logs
  FAKE_DF_AVAIL=$((30 * G)) run "${R[@]}" create bob --size 15G --no-start
  expect_rc "15G tenant with 30G free and alice's 20G cap outstanding" 3
  check "overcommit message explains the arithmetic" err_has "need 35G (15G new + 20G still claimable by existing tenants), 30G free"
  check "refused tenant left no directory" test ! -e "$ROOTD/bob"
  FAKE_DF_AVAIL=$((30 * G)) run "${R[@]}" -n create bob --size 15G
  expect_rc "dry-run reports the overcommit but still renders the plan" 0
  check "dry-run says a real run would stop" err_has "Not enough disk (a real run would stop here)"
  FAKE_DF_AVAIL=$((30 * G)) run "${R[@]}" create bob --size 5G --no-start
  expect_rc "5G tenant fits (25G <= 30G)" 0
  check "--no-start does not start the tenant" argv_lacks "systemctl start omarchy-tenant-bob.service"
  FAKE_DF_AVAIL=$((30 * G)) FAKE_DU_BYTES=$((1 * G)) run "${R[@]}" create carol --size 10G --no-start
  expect_rc "10G more would overcommit" 3
  FAKE_DF_AVAIL=$((30 * G)) run "${R[@]}" create carol --size 10G --no-start --allow-overcommit
  expect_rc "--allow-overcommit" 0
  check "overcommit is warned about" err_has "Overcommitting disk"

  mkdir -p "$ROOTD/.locks"
  hold_lock "$ROOTD/.locks/dave.lock"
  local holder=$HOLDER
  run "${R[@]}" create dave --no-start
  expect_rc "create while another process holds the tenant lock" 75
  check "busy create left no directory" test ! -e "$ROOTD/dave"
  hold_lock "$ROOTD/.locks/alice.lock"
  local holder2=$HOLDER
  run "${R[@]}" key alice add "$KEYS/rsa3072.pub"
  expect_rc "key add while alice is locked" 75
  kill "$holder" "$holder2" 2>/dev/null
  wait "$holder" "$holder2" 2>/dev/null
  run "${R[@]}" -n key alice list
  expect_rc "lock released once the holder exits" 0

  # Minimal PATH: every stub and the basic tools, but no slirp4netns.
  local minbin="$T/minbin" t p
  mkdir -p "$minbin"
  for t in "$FAKEBIN"/*; do
    [[ "${t##*/}" == slirp4netns ]] || ln -sf "$t" "$minbin/"
  done
  ln -sf "$FAKEBIN/.stublib" "$minbin/.stublib"
  for t in bash env cat head tail tr cut sed awk grep mkdir mktemp chmod chown mv rm rmdir ln readlink realpath \
           dirname basename date id getent flock sort uniq wc sleep timeout ssh-keygen setsid stat find xargs ls; do
    p="$(command -v "$t" 2>/dev/null)" && [[ -n "$p" && ! -e "$minbin/$t" ]] && ln -s "$p" "$minbin/$t"
  done
  PATH="$minbin" run "${R[@]}" create erin --no-start
  expect_rc "create without slirp4netns on the host" 3
  check "missing command and its package are named" err_has "slirp4netns (package: slirp4netns)"
  check "missing dependency created nothing" test ! -e "$ROOTD/erin"

  run "${R[@]}" create zed --key "$KEYS/ed" --no-start
  expect_rc "create with a private key as --key" 2
  check "rejected key created nothing" test ! -e "$ROOTD/zed"
  reset_logs
  : >"$T/rootfs.tar"
  run "${R[@]}" create ivan --image "$T/rootfs.tar" --no-start
  expect_rc "create from an --image tarball" 0
  check "tarball extracted with numeric owners into the image" argv_has "tar --numeric-owner -xpf $T/rootfs.tar -C $RUND/ivan/mnt"
  check "--image skips pacstrap" argv_lacks "pacstrap"
  check "tenant.conf records image_source=tarball" test "$(conf_get ivan image_source)" = tarball

  reset_logs
  FAKE_ROOTFS_EMPTY=1 run "${R[@]}" create jack --no-start
  expect_rc "rootfs without sshd/tailscaled" 1
  check "explains what the root lacks" err_has "no tailscaled/sshd"
  check "image unmounted on failure" argv_has "umount $RUND/jack/mnt"
  check "failed tenant stays in state=creating" test "$(conf_get jack state)" = creating

  reset_logs
  mkdir -p "$T/hostetc"
  FAKE_EVIL_ETC="$T/hostetc" run "${R[@]}" create kate --no-start
  expect_rc "image whose /etc is a symlink to a host directory" 1
  check "refuses to write through the symlink" err_has "is a symlink"
  check "host directory untouched" test -z "$(ls -A "$T/hostetc")"
}

# =============================================================================
# 8. Isolation self-check (start / doctor --tenant)
# =============================================================================
test_selfcheck() {
  header "Isolation self-check"
  local status="$FPROC/4242/status" map="$FPROC/4242/uid_map" unit="$UNITD/omarchy-tenant-alice.service" nsp="$NSPD/alice.nspawn"
  reset_logs
  run "${R[@]}" start alice
  expect_rc "start alice (clean)" 0
  reset_logs
  FAKE_PROBE=leak run "${R[@]}" start alice
  expect_rc "start with /mnt/c visible inside" 4
  check "leak reported" err_has "isolation: path:/mnt/c"
  check "leaking tenant stopped" argv_has "systemctl stop omarchy-tenant-alice.service"
  check "leaking tenant disabled" argv_has "systemctl disable omarchy-tenant-alice.service"
  FAKE_PROBE=netleak run "${R[@]}" start alice
  expect_rc "start with the WSL gateway reachable" 4
  check "network leak reported" err_has "isolation: net:172.16.0.1:53"
  FAKE_PROBE=broken run "${R[@]}" start alice
  expect_rc "probe could not run (fail closed)" 4
  FAKE_READY_RC=1 run "${R[@]}" start alice
  expect_rc "container never became reachable (fail closed)" 4
  FAKE_NO_LEADER=1 run "${R[@]}" start alice
  expect_rc "no container leader" 4
  cp "$status" "$T/status.bak"
  printf 'Name:\tsystemd\nNoNewPrivs:\t0\nSeccomp:\t0\n' >"$status"
  run "${R[@]}" start alice
  expect_rc "seccomp and no_new_privs off" 4
  check "seccomp failure reported" err_has "seccomp:not-active"
  check "no_new_privs failure reported" err_has "no-new-privs:off"
  cp "$T/status.bak" "$status"
  cp "$map" "$T/map.bak"
  printf '         0          0 4294967295\n' >"$map"
  run "${R[@]}" start alice
  expect_rc "identity uid map (no user namespace)" 4
  check "user namespace failure reported" err_has "userns:not-private"
  cp "$T/map.bak" "$map"
  cp "$nsp" "$T/nsp.bak"
  printf 'Bind=/mnt/c:/mnt/c\n' >>"$nsp"
  run "${R[@]}" doctor --tenant alice
  expect_rc "doctor --tenant with a Bind= in the .nspawn" 4
  check "forbidden setting reported" out_has "nspawn:forbidden:Bind=/mnt/c:/mnt/c"
  cp "$T/nsp.bak" "$nsp"
  cp "$unit" "$T/unit.bak"
  sed -i '/^IPAddressDeny=/d' "$unit"
  run "${R[@]}" start alice
  expect_rc "start with IPAddressDeny= removed from the unit" 4
  check "missing policy line reported" err_has "policy: unit:IPAddressDeny="
  cp "$T/unit.bak" "$unit"
  run "${R[@]}" doctor --tenant alice
  expect_rc "doctor --tenant alice (restored)" 0
}

# =============================================================================
# 9. SSH public keys
# =============================================================================
test_keys() {
  header "SSH public keys"
  reset_logs
  run "${R[@]}" key alice add "$KEYS/ed"
  expect_rc "private key file refused" 2
  check "refusal says private key" err_has "Refusing private key material"
  check "private key body never echoed" err_lacks "$PRIV_LINE"
  run "${R[@]}" key alice add "$KEYS/opt.pub"
  expect_rc "option-prefixed line refused" 2
  run "${R[@]}" key alice add "$KEYS/rsa2048.pub"
  expect_rc "RSA 2048 refused" 2
  check "RSA refusal names the 3072-bit floor" err_has "at least 3072 bits"
  run "${R[@]}" key alice add "$KEYS/garbage.pub"
  expect_rc "corrupt key refused" 2
  check "refused keys were not stored" test "$(grep -c . "$ROOTD/alice/authorized_keys")" -eq 1
  run "${R[@]}" key alice add "$KEYS/rsa3072.pub"
  expect_rc "RSA 3072 accepted" 0
  check "fingerprint of the added key printed" test "$OUT" = "$RSA_FPR"
  check "pushed into the running tenant over stdin" bash -c "grep -lF '$RSA_B64' '$LOG'/systemd-run.stdin.* >/dev/null"
  run "${R[@]}" key alice add "$KEYS/ed.pub"
  expect_rc "duplicate key" 0
  check "duplicates are not added twice" test "$(grep -c . "$ROOTD/alice/authorized_keys")" -eq 2
  run "${R[@]}" key alice list
  expect_rc "key list" 0
  check "list shows two fingerprints" test "$(grep -c '^SHA256:' "$T/out")" -eq 2
  run "${R[@]}" key alice list --json
  expect_rc "key list --json" 0
  check "key list --json schema" python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == 1 and d["tenant"] == "alice"
ks = d["keys"]
assert len(ks) == 2
for k in ks:
    assert set(k) == {"fingerprint", "type", "bits", "comment"}
    assert k["fingerprint"].startswith("SHA256:") and isinstance(k["bits"], int)
assert sorted(k["type"] for k in ks) == ["ED25519", "RSA"]
assert [k for k in ks if k["type"] == "RSA"][0]["bits"] == 3072
' "$T/out"
  run "${R[@]}" key alice remove "SHA256:$(printf 'A%.0s' {1..43})"
  expect_rc "remove an unknown fingerprint" 5
  reset_logs
  FAKE_ACTIVE=inactive run "${R[@]}" key alice remove "$RSA_FPR"
  expect_rc "remove a key while the tenant is stopped" 0
  check "one key left" test "$(grep -c . "$ROOTD/alice/authorized_keys")" -eq 1
  check "stopped tenant: keys synced by mounting its image" bash -c "grep -q '^mount ' '$LOG/argv.log' && grep -q '^umount ' '$LOG/argv.log'"
  check "image copy updated" bash -c "! grep -qF '$RSA_B64' '$RUND/alice/mnt/etc/omarchy-tenant/authorized_keys'"
  run_in "$KEYS/rsa3072.pub" "${R[@]}" key alice add -
  expect_rc "key add - (stdin)" 0
  check "two keys again" test "$(grep -c . "$ROOTD/alice/authorized_keys")" -eq 2
  run "${R[@]}" key nosuch list
  expect_rc "key list on a missing tenant" 5
  check "argv never carries public key material" bash -c "! grep -qF -e '$ED_B64' -e '$RSA_B64' '$LOG/argv.log'"
  check "no temporary files left behind" tmp_clean
}

# =============================================================================
# 10. Tailnet login: auth URL and auth keys
# =============================================================================
test_auth_url() {
  header "auth-url & auth keys"
  reset_logs
  run "${R[@]}" auth-url alice "$FAKE_ARGV_KEY"
  expect_rc "auth key as an argument" 2
  check "argv key masked in the error" err_has "tskey-****"
  check "argv key never echoed" err_lacks "SECRETVALUE123"
  run "${R[@]}" auth-url alice "--authkey=$FAKE_ARGV_KEY"
  expect_rc "--authkey=tskey-... refused" 2
  check "masked again" err_lacks "SECRETVALUE123"
  run "${R[@]}" auth-url alice --authkey-file "$T/badkey"
  expect_rc "file without a tskey" 2
  reset_logs
  run_in "$T/authkey" "${R[@]}" auth-url alice --authkey-stdin
  expect_rc "auth key on stdin" 0
  check "key copied into the tenant over stdin" bash -c "grep -lF 'kSECRETk' '$LOG'/systemd-run.stdin.* >/dev/null"
  check "tailscale up reads the key from a file inside the tenant" argv_has "--auth-key=file:/run/omarchy-tenant/ts-authkey"
  check "tailscale up runs with --ssh=false --accept-dns=false --accept-routes=false" \
    argv_has "tailscale up --ssh=false --accept-dns=false --accept-routes=false --hostname=alice"
  check "key file removed afterwards" argv_has "rm -f -- /run/omarchy-tenant/ts-authkey"
  check "key never in argv" bash -c "! grep -qF 'kSECRETk' '$LOG/argv.log'"
  check "key never on stdout/stderr" bash -c "! grep -qF 'kSECRETk' '$T/out' '$T/err'"
  run "${R[@]}" auth-url alice --authkey-file "$T/authkey"
  expect_rc "auth key from --authkey-file" 0
  check "still never in argv" bash -c "! grep -qF 'kSECRETk' '$LOG/argv.log'"
  reset_logs
  FAKE_TS_STATUS="$T/ts-needs-login.json" run "${R[@]}" auth-url alice
  expect_rc "interactive login URL" 0
  check "prints exactly the login URL on stdout" test "$OUT" = "https://login.tailscale.com/a/abc123def"
  check "tailscale up started in the background inside the tenant" \
    argv_has "systemd-run --machine=alice --quiet --collect -- tailscale up --ssh=false --accept-dns=false --accept-routes=false --hostname=alice"
  FAKE_TS_STATUS="$T/ts-running.json" run "${R[@]}" auth-url alice
  expect_rc "already logged in" 0
  check "already logged in prints no URL" test -z "$OUT"
  run "${R[@]}" auth-url alice --timeout 1
  expect_rc "no URL within the timeout" 1
  FAKE_ACTIVE=inactive run "${R[@]}" auth-url alice
  expect_rc "auth-url on a stopped tenant" 3
  check "host tailscale/tailscaled never invoked" bash -c "! grep -qE '^(tailscale|tailscaled) ' '$LOG/argv.log'"
  check "never advertises routes or exit nodes" bash -c "! grep -qE -- '--advertise|--exit-node' '$LOG/argv.log'"
}

# =============================================================================
# 11. status / list
# =============================================================================
test_status() {
  header "status & list"
  FAKE_TS_STATUS="$T/ts-running.json" run "${R[@]}" status --json
  expect_rc "status --json" 0
  check "status --json schema" python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"version", "tenants"} and d["version"] == 1
keys = {"name", "state", "size", "mem", "cpus", "tasks", "disk_allocated_bytes", "keys", "tailnet", "isolation"}
for t in d["tenants"]:
    assert set(t) == keys, set(t) ^ keys
    assert t["state"] in {"running", "stopped", "detached", "creating", "failed"}
    assert isinstance(t["cpus"], int) and isinstance(t["tasks"], int)
    assert isinstance(t["disk_allocated_bytes"], int) and isinstance(t["keys"], int)
    assert set(t["tailnet"]) == {"backend_state", "ips"} and isinstance(t["tailnet"]["ips"], list)
    assert set(t["isolation"]) == {"policy", "missing"} and t["isolation"]["policy"] in {"ok", "drift"}
a = [t for t in d["tenants"] if t["name"] == "alice"][0]
assert a["state"] == "running" and a["size"] == "20G" and a["cpus"] == 2 and a["keys"] == 2
assert a["tailnet"] == {"backend_state": "Running", "ips": ["100.101.102.103", "fd7a:115c:a1e0::1"]}
assert a["isolation"] == {"policy": "ok", "missing": []}
j = [t for t in d["tenants"] if t["name"] == "jack"][0]
assert j["state"] == "creating"
' "$T/out"
  FAKE_ACTIVE=inactive run "${R[@]}" status alice --json
  expect_rc "status alice --json (stopped)" 0
  check "stopped tenant has no tailnet state" python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["tenants"][0]
assert t["state"] == "stopped" and t["tailnet"] == {"backend_state": None, "ips": []}
' "$T/out"
  printf '# drift\n' >>"$NSPD/alice.nspawn"
  run "${R[@]}" status alice --json
  check "drift is reported in status" python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["tenants"][0]
assert t["isolation"] == {"policy": "drift", "missing": ["nspawn:content-differs"]}
' "$T/out"
  sed -i '/^# drift$/d' "$NSPD/alice.nspawn"
  run "${R[@]}" status nosuch
  expect_rc "status of a missing tenant" 5
  run "${R[@]}" status
  expect_rc "status (table)" 0
  check "table lists alice" bash -c "grep -qE '^alice +running' '$T/out'"
  run "${R[@]}" list
  expect_rc "list" 0
  check "list prints name<TAB>state" bash -c "grep -qx \$'alice\\trunning' '$T/out'"
  run "${R[@]}" list --json
  check "list --json is valid JSON" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"] == 1 and any(t["name"] == "alice" for t in d["tenants"])' "$T/out"
}

# =============================================================================
# 12. destroy
# =============================================================================
test_destroy() {
  header "destroy"
  reset_logs
  run "${R[@]}" destroy alice
  expect_rc "destroy without --yes (no terminal)" 3
  check "nothing removed without --yes" test -f "$UNITD/omarchy-tenant-alice.service"
  mkdir -p "$T/outside"
  printf 'version=1\nname=evil\n' >"$T/outside/tenant.conf"
  printf 'precious\n' >"$T/outside/disk.raw"
  ln -s "$T/outside" "$ROOTD/evil"
  run "${R[@]}" destroy evil --yes
  expect_rc "destroy a tenant dir that is a symlink out of the root" 3
  check "files outside the root untouched" test "$(cat "$T/outside/disk.raw")" = precious
  rm -f "$ROOTD/evil"
  local before after
  before="$(snapshot)"
  run "${R[@]}" destroy alice --yes --dry-run
  expect_rc "destroy --dry-run" 0
  check "dry-run lists the removals" out_has "[dry-run] rm -f -- $ROOTD/alice/disk.raw"
  after="$(snapshot)"
  check "destroy --dry-run changed nothing" test "$before" = "$after"
  reset_logs
  run "${R[@]}" destroy alice --yes --keep-data
  expect_rc "destroy --keep-data" 0
  check "unit removed" test ! -e "$UNITD/omarchy-tenant-alice.service"
  check ".nspawn removed" test ! -e "$NSPD/alice.nspawn"
  check "disk kept" test -f "$ROOTD/alice/disk.raw"
  check "state=detached" test "$(conf_get alice state)" = detached
  check "unit stopped, disabled and systemd reloaded" \
    bash -c "grep -q '^systemctl stop omarchy-tenant-alice.service' '$LOG/argv.log' && grep -q '^systemctl disable omarchy-tenant-alice.service' '$LOG/argv.log' && grep -q '^systemctl daemon-reload' '$LOG/argv.log'"
  run "${R[@]}" start alice
  expect_rc "start a detached tenant" 3
  reset_logs
  run "${R[@]}" key alice add "$KEYS/ecdsa.pub"
  expect_rc "add an ECDSA key while detached" 0
  check "detached tenant: host copy updated, image left alone until re-attach" \
    bash -c "grep -qF '$EC_B64' '$ROOTD/alice/authorized_keys' && ! grep -qF '$EC_B64' '$RUND/alice/mnt/etc/omarchy-tenant/authorized_keys'"
  check "detached tenant: no mount, no push" bash -c "! grep -qE '^(mount|systemd-run) ' '$LOG/argv.log'"
  reset_logs
  run "${R[@]}" create alice
  expect_rc "create re-attaches a detached tenant" 0
  check "re-attach syncs keys changed while detached into the image" \
    grep -qF "$EC_B64" "$RUND/alice/mnt/etc/omarchy-tenant/authorized_keys"
  check "re-attach never rebuilds the disk" bash -c "! grep -qE '^(truncate|mkfs.ext4|pacstrap|tar) ' '$LOG/argv.log'"
  check "re-attach renders and starts the units" bash -c "grep -q '^systemctl enable omarchy-tenant-alice.service' '$LOG/argv.log' && grep -q '^systemctl start omarchy-tenant-alice.service' '$LOG/argv.log'"
  check "state=ready again" test "$(conf_get alice state)" = ready
  golden "$UNITD/omarchy-tenant-alice.service" omarchy-tenant-alice.service.golden
  printf 'notes\n' >"$ROOTD/bob/notes.txt"
  run "${R[@]}" destroy bob --yes
  expect_rc "destroy bob with an unknown file in its directory" 0
  check "unknown file kept" test -f "$ROOTD/bob/notes.txt"
  check "known files removed" bash -c "[[ ! -e '$ROOTD/bob/disk.raw' && ! -e '$ROOTD/bob/tenant.conf' && ! -e '$ROOTD/bob/authorized_keys' ]]"
  check "warns that the directory was kept" err_has "Kept $ROOTD/bob"
  run "${R[@]}" destroy alice --yes
  expect_rc "destroy alice" 0
  check "tenant directory removed" test ! -e "$ROOTD/alice"
  check "units removed" bash -c "[[ ! -e '$UNITD/omarchy-tenant-alice.service' && ! -e '$NSPD/alice.nspawn' ]]"
  run "${R[@]}" destroy nosuch --yes
  expect_rc "destroy a missing tenant" 5
}

# =============================================================================
# 13. _net-up (ExecStartPost), doctor, io_uring opt-in, signals
# =============================================================================
test_net_up() {
  header "_net-up attaches slirp4netns"
  reset_logs
  rm -rf "$FPROC/4242/net"
  run _net-up carol
  expect_rc "_net-up carol" 0
  check "slirp4netns hardened flags" argv_has "slirp4netns --configure --mtu=65520 --disable-host-loopback --disable-dns --enable-sandbox --enable-seccomp 4242 tap0"
  check "pid file written" test -s "$RUND/carol/slirp4netns.pid"
  reset_logs
  run _net-up carol
  expect_rc "_net-up when tap0 already exists" 0
  check "no second slirp4netns" argv_lacks "slirp4netns"
  rm -rf "$FPROC/4242/net"
  FAKE_SLIRP_NO_TAP=1 run _net-up carol
  expect_rc "tap0 never appears" 1
  FAKE_NO_LEADER=1 run _net-up carol
  expect_rc "no container leader" 1
}

test_doctor_io_uring() {
  header "doctor & io_uring opt-in"
  reset_logs
  run "${R[@]}" doctor
  expect_rc "doctor on a complete host" 0
  check "doctor reports io_uring_disabled=0" out_has "kernel.io_uring_disabled=0"
  check "doctor never writes sysctl" bash -c "! grep -q '^sysctl ' '$LOG/argv.log' && [[ ! -e '$SYSD/60-omarchy-tenant-io-uring.conf' ]]"
  rm -f "$T/dev/net/tun"
  run "${R[@]}" doctor
  expect_rc "doctor without /dev/net/tun" 3
  : >"$T/dev/net/tun"
  reset_logs
  run "${R[@]}" create frank --no-start
  expect_rc "create frank" 0
  check "no sysctl file without the opt-in" test ! -e "$SYSD/60-omarchy-tenant-io-uring.conf"
  run "${R[@]}" create gina --no-start --harden-host-io-uring
  expect_rc "create gina --harden-host-io-uring" 0
  check "opt-in writes kernel.io_uring_disabled = 2" grep -qx 'kernel.io_uring_disabled = 2' "$SYSD/60-omarchy-tenant-io-uring.conf"
  check "opt-in applies it" argv_has "sysctl -p $SYSD/60-omarchy-tenant-io-uring.conf"
}

test_signals() {
  header "Signals & resume"
  reset_logs
  FAKE_SLEEP_IN=pacstrap FAKE_SLEEP_SECS=2 "$TOOL" "${R[@]}" create hank --no-start >"$T/out" 2>"$T/err" </dev/null &
  local pid=$! i rc=0
  for (( i = 0; i < 100; i++ )); do
    grep -q '^pacstrap ' "$LOG/argv.log" 2>/dev/null && break
    sleep 0.1
  done
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  check "SIGTERM during create exits 143" test "$rc" -eq 143
  check "interruption explained" err_has "Interrupted by SIGTERM"
  check "image unmounted by the signal handler" bash -c "grep -q '^umount ' '$LOG/argv.log'"
  check "state stays creating" test "$(conf_get hank state)" = creating
  check "journal stops before rootfs" bash -c "! grep -qx rootfs '$ROOTD/hank/journal'"
  check "no temporary files left behind" tmp_clean
  reset_logs
  run "${R[@]}" create hank --no-start
  expect_rc "re-run resumes" 0
  check "resume skips the finished disk step" bash -c "! grep -qE '^(truncate|mkfs.ext4) ' '$LOG/argv.log'"
  check "resume redoes the rootfs step" argv_has "pacstrap -c -K"
  check "state=ready after resume" test "$(conf_get hank state)" = ready
}

test_secrets_final() {
  header "Secret hygiene (every command recorded during the whole run)"
  local all="$T/all-argv.log"
  check "the run recorded commands" test -s "$all"
  check "no Tailscale auth key in any argv" bash -c "! grep -qF -e 'kSECRETk' -e 'SECRETVALUE123' '$all'"
  check "no public key material in any argv" bash -c "! grep -qF -e '$ED_B64' -e '$RSA_B64' -e '$EC_B64' '$all'"
  check "no private key material in any argv" bash -c "! grep -qF -- '$PRIV_LINE' '$all'"
}

test_static
test_cli
test_root
test_names
test_dry_run
test_create
test_unit_verify
test_idempotent
test_preconditions
test_selfcheck
test_keys
test_auth_url
test_status
test_destroy
test_net_up
test_doctor_io_uring
test_signals
test_secrets_final

echo
echo "Tenant Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
if (( TESTS_FAILED > 0 )); then
  exit 1
fi
if (( TESTS_SKIPPED > 0 && STRICT == 1 )); then
  echo "OMW_STRICT=1: skipped checks count as failures."
  exit 1
fi
exit 0
