#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Windows Integration & QoL Adversarial Test Suite
# /tests/test_windows_integration.sh
# ==============================================================================
# Exercises every tool from docs/WINDOWS-INTEGRATION-QOL.md against a
# simulated Windows host: a fake DrvFs tree (C:, D:), stub powershell.exe /
# cmd.exe / clip.exe / rundll32.exe / explorer.exe / reg.exe that record their
# argv, stdin and decoded -EncodedCommand scripts, plus real end-to-end paths
# where the host allows it (ssh-agent through the bridge, inotify events,
# Docker API pings over unix sockets, live/stale AF_UNIX interop sockets).
#
# Tools used when present: shellcheck, pwsh (parses every generated PowerShell
# script), socat, ssh-agent, gpg-agent, inotifywait, curl, python3, script.
# A missing tool is reported as SKIP; with OMW_STRICT=1 any skip makes the
# suite exit non-zero (tests/ci/Containerfile installs all of them).
#   SHELLCHECK=/path/to/shellcheck PWSH=/path/to/pwsh bash tests/test_windows_integration.sh
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
header() { printf '\n%s>>> TEST SUITE: %s%s\n' "$C_HDR" "$*" "$C_END"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck || true)}"
PWSH="${PWSH:-$(command -v pwsh || true)}"

BIN="${ROOT_DIR}/bin"
WSLBIN="${ROOT_DIR}/wsl/bin"
TOOLS=(
  "$BIN/omarchy-open" "$BIN/omarchy-clip" "$BIN/omarchy-sync-dirs" "$BIN/omarchy-notify"
  "$BIN/omarchy-docker-bridge" "$BIN/omarchy-watch-bridge" "$BIN/omarchy-power-governor"
  "$BIN/omarchy-build" "$WSLBIN/omarchy-ssh-agent-bridge" "$WSLBIN/omarchy-git-credential-bridge"
  "$BIN/omarchy-ca-sync" "$BIN/omarchy-dns-sync" "$BIN/omarchy-proxy-sync"
)

# -----------------------------------------------------------------------------
# Simulated Windows host
# -----------------------------------------------------------------------------
T=$(mktemp -d "${TMPDIR:-/tmp}/omw-test.XXXXXX")
BG_PIDS=()
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() {
  local p f
  for p in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
  for f in "$T"/run/omarchy/*.pid; do
    [[ -f "$f" ]] || continue
    kill -TERM -- "-$(cat "$f")" 2>/dev/null || kill "$(cat "$f")" 2>/dev/null || true
  done
  # OMW_TEST_KEEP=1 keeps the sandbox for inspection (processes are still reaped).
  if [[ -n "${OMW_TEST_KEEP:-}" ]]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

MNT="$T/mnt"
SYS32="$MNT/c/Windows/System32"
WINHOME="$MNT/c/Users/Jane Doe"
LOG="$T/log"
mkdir -p "$SYS32/WindowsPowerShell/v1.0" "$WINHOME/AppData/Local" "$WINHOME/Downloads" \
         "$WINHOME/OneDrive/Desktop" "$MNT/d/Docs" "$LOG" "$T/run" "$T/home" "$T/fakebin"
chmod 0700 "$T/run"

# Generic recorder: logs argv (one per line, NUL-free) and stdin.
make_recorder() {
  local path="$1" name="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
{ printf '%s\n' "---"; printf '%s\n' "\$@"; } >>"$LOG/$name.argv"
if [[ ! -t 0 ]]; then cat >"$LOG/$name.stdin"; fi
exit 0
EOF
  chmod +x "$path"
}
make_recorder "$SYS32/clip.exe" clip
make_recorder "$SYS32/rundll32.exe" rundll32
make_recorder "$MNT/c/Windows/explorer.exe" explorer
cat >"$SYS32/reg.exe" <<'EOF'
#!/usr/bin/env bash
printf '\r\nHKEY_CURRENT_USER\\Software\\...\\UserChoice\r\n    ProgId    REG_SZ    FirefoxURL-308046B0AF4A39CB\r\n\r\n'
EOF
chmod +x "$SYS32/reg.exe"

# cmd.exe: only answers `/d /c "echo %VAR%"` for a fixed environment (CRLF).
export OMW_TEST_LOG="$LOG"
cat >"$SYS32/cmd.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OMW_TEST_LOG:-/dev/null}/cmd.calls"
case "$*" in
  *%USERPROFILE%*) printf 'C:\\Users\\Jane Doe\r\n' ;;
  *%LOCALAPPDATA%*) printf 'C:\\Users\\Jane Doe\\AppData\\Local\r\n' ;;
  *) printf '%s\r\n' "${3#echo }" ;;
esac
EOF
chmod +x "$SYS32/cmd.exe"

# powershell.exe: decodes -EncodedCommand, records the script, records stdin,
# replies with $FAKE_PS_OUT (file) and exits $FAKE_PS_RC.
cat >"$SYS32/WindowsPowerShell/v1.0/powershell.exe" <<EOF
#!/usr/bin/env bash
enc=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == "-EncodedCommand" ]] && enc="\$2"
  shift
done
n=\$(( \$(ls "$LOG"/ps.*.ps1 2>/dev/null | wc -l) + 1 ))
printf '%s' "\$enc" | base64 -d | iconv -f UTF-16LE -t UTF-8 >"$LOG/ps.\$n.ps1"
printf '%s' "\${WSL_INTEROP:-}" >"$LOG/ps.\$n.interop"
if [[ ! -t 0 ]]; then cat >"$LOG/ps.\$n.stdin"; fi
if [[ -n "\${FAKE_PS_OUT:-}" && -f "\${FAKE_PS_OUT}" ]]; then cat "\$FAKE_PS_OUT"; fi
exit "\${FAKE_PS_RC:-0}"
EOF
chmod +x "$SYS32/WindowsPowerShell/v1.0/powershell.exe"

export OMW_FORCE_WSL=1 OMW_FORCE_INTEROP=1 OMW_MOUNT_ROOT="$MNT"
export XDG_RUNTIME_DIR="$T/run" HOME="$T/home" WSL_DISTRO_NAME="Omarchy"
export XDG_CONFIG_HOME="$T/home/.config"
unset SSH_CONNECTION SSH_TTY TMUX DOCKER_HOST BROWSER WAYLAND_DISPLAY
# The stub numbers its scripts ps.1.ps1, ps.2.ps1, ...
ps_count() { find "$LOG" -maxdepth 1 -name 'ps.*.ps1' 2>/dev/null | wc -l; }
ps_last() { local n; n=$(ps_count); (( n > 0 )) && echo "$LOG/ps.$n.ps1"; }
ps_last_stdin() { echo "$LOG/ps.$(ps_count).stdin"; }
reset_logs() { rm -f "$LOG"/*; rm -f "$T/run/omarchy"/cache-* 2>/dev/null; true; }

# shellcheck source=SCRIPTDIR/../lib/omarchy-wsl-interop.sh
source "$ROOT_DIR/lib/omarchy-wsl-interop.sh"

cat >"$T/parse.ps1" <<'PS'
param([string]$Path)
$errs = $null; $tok = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 }
PS
# shellcheck disable=SC2317  # called through check()
pwsh_parses() {
  # Parse-only check: no execution, so Windows-only types are irrelevant.
  "$PWSH" -NoProfile -NonInteractive -File "$T/parse.ps1" -Path "$1" >/dev/null
}
# pwsh_check <desc> <script>: parse a generated script, or SKIP without pwsh.
pwsh_check() {
  if [[ -z "$PWSH" ]]; then skip "pwsh not installed: $1"; return; fi
  if [[ -z "${2:-}" || ! -f "$2" ]]; then fail "$1 (no script captured)"; return; fi
  check "$1" pwsh_parses "$2"
}

# =============================================================================
# 0. Static analysis & repository safety invariants
# =============================================================================
test_static() {
  header "0. Syntax, Lint & Safety Invariants"
  local f bad=0
  for f in "${TOOLS[@]}" "$ROOT_DIR/lib/omarchy-wsl-interop.sh" "$ROOT_DIR/wsl/lib/drvfs-guard.sh"; do
    bash -n "$f" 2>/dev/null || { bad=1; echo "      syntax: $f"; }
  done
  check "All integration scripts pass bash -n" test $bad -eq 0

  bad=0
  for f in "$ROOT_DIR"/wsl/profile.d/20-omarchy-*.sh "$ROOT_DIR"/wsl/profile.d/30-omarchy-ssh-agent.sh \
           "$ROOT_DIR"/wsl/profile.d/40-omarchy-drvfs-guard.sh "$ROOT_DIR"/wsl/profile.d/50-omarchy-docker.sh; do
    sh -n "$f" 2>/dev/null || { bad=1; echo "      sh -n: $f"; }
  done
  check "profile.d snippets are POSIX sh parseable" test $bad -eq 0

  bad=0
  for f in "${TOOLS[@]}"; do [[ -x "$f" ]] || { bad=1; echo "      not executable: $f"; }; done
  check "All tools are executable" test $bad -eq 0

  bad=0
  for f in "${TOOLS[@]}"; do grep -q '^set -[eu]*o pipefail\|^set -euo pipefail\|^set -uo pipefail' "$f" || { bad=1; echo "      no strict mode: $f"; }; done
  check "All tools run in strict mode (set -u -o pipefail)" test $bad -eq 0

  if [[ -n "$SHELLCHECK" ]]; then
    if (cd "$ROOT_DIR" && "$SHELLCHECK" -x "${TOOLS[@]}" lib/omarchy-wsl-interop.sh wsl/lib/drvfs-guard.sh \
          wsl/bin/wsl-shims-setup.sh wsl/profile.d/[1-5]*.sh >/dev/null 2>&1); then
      pass "shellcheck -x is clean (all severities)"
    else
      fail "shellcheck reported warnings"
    fi
  else
    skip "shellcheck not installed"
  fi

  check "wsl.conf keeps appendWindowsPath=false (no Windows PATH pollution)" \
    grep -q '^appendWindowsPath = false' "$ROOT_DIR/wsl/wsl.conf"

  # cmd.exe may only ever run the fixed `echo %VAR%` probe (VAR regex-checked).
  local cmd_uses
  cmd_uses=$(grep -n 'cmd\.exe' "${TOOLS[@]}" "$ROOT_DIR/lib/omarchy-wsl-interop.sh" | grep -v '^\S*:[0-9]*:\s*#' | grep -vc 'omw_find_exe cmd.exe' || true)
  check "No tool shells out to cmd.exe with user data" test "$cmd_uses" -eq 0

  local evals
  # eval used as a command (messages that merely mention eval are fine)
  evals=$(cat "${TOOLS[@]}" "$ROOT_DIR/lib/omarchy-wsl-interop.sh" | grep -Ec '(^|[;&|(])[[:space:]]*eval[[:space:]]' || true)
  check "No eval in integration tools" test "$evals" -eq 0

  check "PowerShell is only invoked with -EncodedCommand" \
    bash -c "! grep -n 'powershell.exe.* -Command ' '${ROOT_DIR}/lib/omarchy-wsl-interop.sh' ${TOOLS[*]}"

  pwsh_check "register-explorer-context-menu.ps1 parses (pwsh)" "$ROOT_DIR/tools/register-explorer-context-menu.ps1"
}

# =============================================================================
# 1. Interop library
# =============================================================================
test_interop_lib() {
  header "1. Shared Interop Library (path translation, encoding, detection)"
  check "C:\\Users\\x -> <mnt>/c/Users/x" test "$(omw_win_to_unix 'C:\Users\x')" = "$MNT/c/Users/x"
  check "D:/data -> <mnt>/d/data" test "$(omw_win_to_unix 'D:/data')" = "$MNT/d/data"
  # shellcheck disable=SC1003  # a literal backslash path
  check "Drive root C:\\ -> <mnt>/c" test "$(omw_win_to_unix 'C:\')" = "$MNT/c"
  check "\\\\wsl.localhost\\Omarchy\\home\\u -> /home/u" test "$(omw_win_to_unix '\\wsl.localhost\Omarchy\home\u')" = "/home/u"
  check "\\\\wsl\$\\omarchy (case-insensitive distro) -> /etc" test "$(omw_win_to_unix '\\wsl$\omarchy\etc')" = "/etc"
  check "Foreign distro UNC path is not mis-translated" bash -c "! (source '$ROOT_DIR/lib/omarchy-wsl-interop.sh'; PATH=/usr/bin:/bin omw_win_to_unix '\\\\wsl.localhost\\Ubuntu\\home\\u')"
  check "<mnt>/c/a b/c -> C:\\a b\\c" test "$(omw_unix_to_win "$MNT/c/a b/c")" = 'C:\a b\c'
  check "/home/u -> \\\\wsl.localhost\\Omarchy\\home\\u" test "$(omw_unix_to_win /home/u)" = '\\wsl.localhost\Omarchy\home\u'

  printf '[boot]\nsystemd=true\n[automount]\nroot = "/win/"\n' >"$T/wsl.conf"
  check "Automount root parsed from wsl.conf ([automount] root=/win/)" \
    test "$(OMW_MOUNT_ROOT='' OMW_WSL_CONF="$T/wsl.conf" bash -c "source '$ROOT_DIR/lib/omarchy-wsl-interop.sh'; omw_mount_root")" = "/win"

  local s="Write-Host 'héllo ✓ \"q\" \$x'"
  check "EncodedCommand round-trips UTF-8 through UTF-16LE base64" \
    test "$(omw_ps_encode "$s" | base64 -d | iconv -f UTF-16LE -t UTF-8)" = "$s"
  check "EncodedCommand contains only base64 characters" bash -c "[[ \"$(omw_ps_encode "$s")\" =~ ^[A-Za-z0-9+/=]+\$ ]]"

  cat >"$T/mountinfo" <<EOF
22 1 8:1 / / rw - ext4 /dev/sdc rw
80 22 0:50 / $MNT/c rw,noatime - 9p C:\\134 rw,dirsync,aname=drvfs;path=C:\\
EOF
  check "DrvFs detected under a 9p drvfs mount" env OMW_MOUNTINFO="$T/mountinfo" bash -c "source '$ROOT_DIR/lib/omarchy-wsl-interop.sh'; omw_is_drvfs '$MNT/c/proj'"
  check "ext4 path is not DrvFs" env OMW_MOUNTINFO="$T/mountinfo" bash -c "source '$ROOT_DIR/lib/omarchy-wsl-interop.sh'; ! omw_is_drvfs '$T/home'"
  check "Prefix confusion (<mnt>/cx) is not DrvFs" env OMW_MOUNTINFO="$T/mountinfo" bash -c "source '$ROOT_DIR/lib/omarchy-wsl-interop.sh'; ! omw_is_drvfs '$MNT/cx/proj'"

  local rd; rd=$(omw_runtime_dir)
  check "Runtime dir is private (0700)" test "$(stat -c %a "$rd")" = "700"
  check "omw_win_env reads %USERPROFILE% without CR" test "$(omw_win_env USERPROFILE)" = 'C:\Users\Jane Doe'
  check "omw_win_env rejects injection-shaped variable names" bash -c "source '$ROOT_DIR/lib/omarchy-wsl-interop.sh'; ! omw_win_env 'X%&calc'"
}

# =============================================================================
# 1b. Stale $WSL_INTEROP repair
# =============================================================================
# start_unix_listener <path>: background AF_UNIX listener (stands in for a live
# WSL session's interop server).
start_unix_listener() {
  python3 - "$1" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(16)
while True:
    c, _ = s.accept()
    c.close()
PY
  BG_PIDS+=($!)
  local _i
  for _i in $(seq 50); do [[ -S "$1" ]] && return 0; sleep 0.1; done
  return 1
}

test_interop_fix() {
  header "1b. Stale \$WSL_INTEROP repair (omw_fix_interop)"
  if ! have python3; then skip "python3 unavailable: AF_UNIX interop socket tests disabled"; return; fi
  local rd="$T/runwsl" rd2="$T/runwsl-dead" lib="$ROOT_DIR/lib/omarchy-wsl-interop.sh" out rc
  mkdir -p "$rd" "$rd2"
  start_unix_listener "$rd/200_interop" || { fail "could not start the live interop listener"; return; }
  # Dead session: the socket file stays behind but nobody listens. It is made
  # NEWER than the live one, so "newest" alone would pick the wrong socket.
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$rd/300_interop"
  cp -a "$rd/300_interop" "$rd2/300_interop" 2>/dev/null || \
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$rd2/300_interop"
  : >"$rd/400_interop"   # not a socket
  touch -h -d '2020-01-01 00:00:00' "$rd/200_interop"
  touch -h -d '2030-01-01 00:00:00' "$rd/300_interop"

  local probe="source '$lib'; omw_fix_interop; rc=\$?; echo \"\$rc \${WSL_INTEROP:-}\""
  out=$(env -u OMW_FORCE_INTEROP OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/999_interop" bash -c "$probe")
  check "Missing socket -> newest LIVE /run/WSL socket (newer dead one skipped)" test "$out" = "0 $rd/200_interop"
  out=$(env -u OMW_FORCE_INTEROP OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/300_interop" bash -c "$probe")
  check "Socket file without a listener is treated as stale" test "$out" = "0 $rd/200_interop"
  out=$(env -u OMW_FORCE_INTEROP -u WSL_INTEROP OMW_WSL_RUN_DIR="$rd" bash -c "$probe")
  check "Unset \$WSL_INTEROP (systemd services) -> live socket exported" test "$out" = "0 $rd/200_interop"
  out=$(env -u OMW_FORCE_INTEROP OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/200_interop" bash -c "$probe")
  check "A live \$WSL_INTEROP is kept" test "$out" = "0 $rd/200_interop"
  out=$(env -u OMW_FORCE_INTEROP OMW_PROC_NET_UNIX=/dev/null OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/999_interop" bash -c "$probe")
  check "connect() probe works without /proc/net/unix" test "$out" = "0 $rd/200_interop"
  out=$(env -u OMW_FORCE_INTEROP OMW_WSL_RUN_DIR="$rd2" WSL_INTEROP="$rd2/300_interop" bash -c "$probe")
  check "No live socket anywhere -> non-zero, \$WSL_INTEROP untouched" test "$out" = "1 $rd2/300_interop"

  reset_logs
  OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/999_interop" bash -c "source '$lib'; omw_ps_run 'Write-Output 1' >/dev/null"
  check "omw_ps_run launches powershell.exe with the repaired socket" \
    test "$(cat "$LOG/ps.1.interop" 2>/dev/null)" = "$rd/200_interop"
  reset_logs
  out=$(env -u OMW_FORCE_INTEROP OMW_WSL_RUN_DIR="$rd2" WSL_INTEROP="$rd2/300_interop" \
        bash -c "source '$lib'; omw_ps_run 'Write-Output 1'" 2>&1); rc=$?
  check "Unrepairable stale socket fails fast (126) with a diagnosis" \
    bash -c "[[ $rc -eq 126 && \"\$1\" == *stale* ]] && (( \$(find '$LOG' -name 'ps.*.ps1' | wc -l) == 0 ))" _ "$out"

  omw_write_exec_wrapper "$T/wrap-interop.sh" printenv WSL_INTEROP
  out=$(OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/300_interop" "$T/wrap-interop.sh")
  check "socat relay wrapper re-resolves the live socket on every connection" test "$out" = "$rd/200_interop"

  # omw_win_env: cache keyed on the interop session, paths re-validated, short TTL.
  reset_logs
  OMW_WSL_RUN_DIR="$rd" WSL_INTEROP="$rd/200_interop" bash -c "source '$lib'; omw_win_env USERPROFILE" >/dev/null
  check "omw_win_env cache key includes the interop session identity" \
    bash -c "compgen -G '$T/run/omarchy/cache-winenv-USERPROFILE-200_interop-*' >/dev/null"
  printf 'C:\\Users\\Gone\n' >"$T/run/omarchy/cache-winenv-USERPROFILE-none"
  out=$(OMW_WSL_RUN_DIR=/nonexistent bash -c "unset WSL_INTEROP; source '$lib'; omw_win_env USERPROFILE")
  check "Cached Windows path that no longer exists is re-queried" test "$out" = 'C:\Users\Jane Doe'
  rm -f "$LOG/cmd.calls"
  touch -d '-400 seconds' "$T/run/omarchy/cache-winenv-USERPROFILE-none"
  OMW_WSL_RUN_DIR=/nonexistent bash -c "unset WSL_INTEROP; source '$lib'; omw_win_env USERPROFILE" >/dev/null
  check "omw_win_env cache expires within 5 minutes" test -s "$LOG/cmd.calls"

  # Colour: only for a terminal on stderr, never with NO_COLOR.
  out=$(bash -c "source '$lib'; omw_warn hello" 2>&1)
  check "No ANSI colour when stderr is not a terminal" bash -c "[[ \"\$1\" != *$'\\e'* ]]" _ "$out"
  if have script; then
    out=$(script -qec "bash -c \"source '$lib'; omw_warn hello\"" /dev/null 2>/dev/null)
    check "Colour on a terminal" bash -c "[[ \"\$1\" == *$'\\e['* ]]" _ "$out"
    out=$(NO_COLOR=1 script -qec "bash -c \"source '$lib'; omw_warn hello\"" /dev/null 2>/dev/null)
    check "NO_COLOR disables colour even on a terminal" bash -c "[[ \"\$1\" == *hello* && \"\$1\" != *$'\\e['* ]]" _ "$out"
  else
    skip "script (util-linux) unavailable: tty colour checks disabled"
  fi
}

# =============================================================================
# 1c. Runtime directory
# =============================================================================
test_runtime_dir() {
  header "1c. Runtime directory (private, never a predictable /tmp path)"
  local lib="$ROOT_DIR/lib/omarchy-wsl-interop.sh" h="$T/rt-home" out rc
  mkdir -p "$h"
  out=$(env -u XDG_RUNTIME_DIR -u XDG_CACHE_HOME HOME="$h" bash -c "source '$lib'; omw_runtime_dir")
  check "No XDG_RUNTIME_DIR -> \$HOME/.cache/omarchy/run" test "$out" = "$h/.cache/omarchy/run"
  check "Every fallback component is created 0700" \
    bash -c "[[ \$(stat -c %a '$h/.cache') == 700 && \$(stat -c %a '$h/.cache/omarchy') == 700 && \$(stat -c %a '$h/.cache/omarchy/run') == 700 ]]"
  check "No /tmp/omarchy-runtime-UID fallback is created" test ! -e "/tmp/omarchy-runtime-$(id -u)"
  mkdir -p "$T/rt-gw" && chmod 0777 "$T/rt-gw"
  out=$(env -u XDG_CACHE_HOME XDG_RUNTIME_DIR="$T/rt-gw" HOME="$h" bash -c "source '$lib'; omw_runtime_dir")
  check "World-writable XDG_RUNTIME_DIR is not trusted" test "$out" = "$h/.cache/omarchy/run"
  ln -sfn "$h/.cache" "$T/rt-link"
  env -u XDG_RUNTIME_DIR XDG_CACHE_HOME="$T/rt-link" bash -c "source '$lib'; omw_runtime_dir" >/dev/null 2>&1; rc=$?
  check "Symlinked cache base is refused" test "$rc" -ne 0
  mkdir -p "$T/rt-x" && chmod 0700 "$T/rt-x" && ln -sfn "$T/rt-gw" "$T/rt-x/omarchy"
  env -u XDG_CACHE_HOME XDG_RUNTIME_DIR="$T/rt-x" HOME="$h" bash -c "source '$lib'; omw_runtime_dir" >/dev/null 2>&1; rc=$?
  check "Symlinked \$XDG_RUNTIME_DIR/omarchy is refused" test "$rc" -ne 0
  if (( EUID == 0 )); then
    mkdir -p "$T/rt-foreign/omarchy" && chown 4242:4242 "$T/rt-foreign/omarchy"
    env -u XDG_RUNTIME_DIR XDG_CACHE_HOME="$T/rt-foreign" bash -c "source '$lib'; omw_runtime_dir" >/dev/null 2>&1; rc=$?
  else
    # A directory owned by root stands in for one pre-created by another user.
    env -u XDG_RUNTIME_DIR XDG_CACHE_HOME=/usr/share bash -c "source '$lib'; omw_runtime_dir" >/dev/null 2>&1; rc=$?
  fi
  check "Cache component owned by another user is refused" test "$rc" -ne 0
}

# =============================================================================
# 2. omarchy-open
# =============================================================================
test_open() {
  header "2. omarchy-open (URL / file / editor launcher)"
  local out
  out=$("$BIN/omarchy-open" --print 'https://omarchy.org/a?b=1&c=2')
  check "https URL -> rundll32 url.dll,FileProtocolHandler (no cmd.exe)" \
    bash -c "grep -qF 'rundll32.exe' <<<\"\$1\" && grep -qF \"\$(printf %q 'url.dll,FileProtocolHandler')\" <<<\"\$1\" && grep -qF \"\$(printf %q 'https://omarchy.org/a?b=1&c=2')\" <<<\"\$1\"" _ "$out"
  out=$("$BIN/omarchy-open" --print 'https://x.test/a b"c<d>|e^f')
  check "Spaces/quotes/metacharacters are percent-encoded" bash -c "[[ '$out' == *'a%20b%22c%3Cd%3E%7Ce%5Ef'* ]]"
  check "ms-msdt: (Follina) refused" bash -c "! '$BIN/omarchy-open' --print 'ms-msdt:/id PCWDiagnostic' 2>/dev/null"
  check "search-ms: refused" bash -c "! '$BIN/omarchy-open' --print 'search-ms:query=x&crumb=location:\\\\evil\\share' 2>/dev/null"
  check "javascript: refused" bash -c "! '$BIN/omarchy-open' --print 'javascript:alert(1)' 2>/dev/null"
  check "--allow-scheme vscode permits vscode:// for one call" bash -c "'$BIN/omarchy-open' --print --allow-scheme vscode 'vscode://file/x' >/dev/null"
  check "Control characters in URLs refused" bash -c "! '$BIN/omarchy-open' --print \$'https://x.test/\\x01' 2>/dev/null"
  check "www.* gains https://" bash -c "[[ \"\$('$BIN/omarchy-open' --print www.example.com)\" == *https://www.example.com* ]]"

  mkdir -p "$MNT/c/files"
  : >"$MNT/c/files/report.pdf"; : >"$MNT/c/files/setup.exe"; : >"$MNT/c/files/Shortcut.LNK"; : >"$MNT/c/files/a,b.txt"
  out=$("$BIN/omarchy-open" --print "$MNT/c/files/report.pdf")
  check "Document opens via explorer.exe with a Windows path" \
    bash -c "grep -qF explorer.exe <<<\"\$1\" && grep -qF \"\$(printf %q 'C:\\files\\report.pdf')\" <<<\"\$1\"" _ "$out"
  check "Executable (.exe) refused without --force" bash -c "! '$BIN/omarchy-open' --print '$MNT/c/files/setup.exe' 2>/dev/null"
  check "Case-insensitive guard (.LNK) refused" bash -c "! '$BIN/omarchy-open' --print '$MNT/c/files/Shortcut.LNK' 2>/dev/null"
  check "--force allows an executable explicitly" bash -c "'$BIN/omarchy-open' --print --force '$MNT/c/files/setup.exe' >/dev/null"
  check "file:// URI to an .exe is still refused" bash -c "! '$BIN/omarchy-open' --print 'file://$MNT/c/files/setup.exe' 2>/dev/null"
  out=$("$BIN/omarchy-open" --print "$MNT/c/files/a,b.txt")
  check "Comma path (explorer separator) routed to PowerShell -LiteralPath" bash -c "[[ '$out' == *Start-Process\ -LiteralPath* ]]"
  out=$("$BIN/omarchy-open" --print 'C:\files\report.pdf')
  check "Windows-style path argument is treated as a path, not a URL" bash -c "[[ '$out' == *explorer.exe* ]]"
  out=$("$BIN/omarchy-open" --print "$T/home")
  check "Linux directory opens as \\\\wsl.localhost UNC in Explorer" bash -c "[[ '$out' == *wsl.localhost*Omarchy* ]]"

  reset_logs
  "$BIN/omarchy-open" 'https://example.com/x?y=1' >/dev/null 2>&1
  check "Live launch passes URL as a single argv element to rundll32" \
    bash -c "grep -qx 'https://example.com/x?y=1' '$LOG/rundll32.argv' && grep -qx 'url.dll,FileProtocolHandler' '$LOG/rundll32.argv'"
  check "--default-browser reads UserChoice ProgId via reg.exe" \
    test "$("$BIN/omarchy-open" --default-browser 2>/dev/null)" = "FirefoxURL-308046B0AF4A39CB"
}

# =============================================================================
# 3. omarchy-clip
# =============================================================================
test_clip() {
  header "3. omarchy-clip (clipboard router, OSC 52)"
  reset_logs
  printf 'héllo ✓ wörld' | "$BIN/omarchy-clip" copy
  check "Windows copy writes a UTF-16LE BOM to clip.exe" bash -c "[[ \"\$(head -c2 '$LOG/clip.stdin' | od -An -tx1 | tr -d ' ')\" == fffe ]]"
  check "clip.exe payload decodes back to the exact UTF-8 text" \
    test "$(tail -c +3 "$LOG/clip.stdin" | iconv -f UTF-16LE -t UTF-8)" = "héllo ✓ wörld"

  reset_logs
  printf 'a\nb\nc' | "$BIN/omarchy-clip" copy --crlf
  check "--crlf converts LF->CRLF without inventing a trailing CR" \
    test "$(tail -c +3 "$LOG/clip.stdin" | iconv -f UTF-16LE -t UTF-8 | od -An -c | tr -s ' ')" = " a \r \n b \r \n c"

  printf 'line1\r\nline2\r\n' >"$T/ps_text.out"
  check "Paste strips CR from Windows CRLF text" \
    test "$(FAKE_PS_OUT="$T/ps_text.out" "$BIN/omarchy-clip" paste | od -An -c | tr -s ' ')" = " l i n e 1 \n l i n e 2 \n"

  # stdin is an open pipe that never delivers data or EOF for 20 s.
  check "PowerShell never inherits stdin (idle pipe does not block paste)" \
    bash -c "[[ \"\$(FAKE_PS_OUT='$T/ps_text.out' timeout 8 '$BIN/omarchy-clip' paste < <(sleep 20))\" == \$'line1\\nline2' ]]"

  printf '\x89PNG\r\n\x1a\nfakeimagedata\x00\xff' >"$T/img.png"
  base64 -w0 "$T/img.png" >"$T/ps_img.out"
  FAKE_PS_OUT="$T/ps_img.out" "$BIN/omarchy-clip" paste -t image/png >"$T/img.out"
  check "Image paste returns byte-identical PNG data" cmp -s "$T/img.png" "$T/img.out"
  reset_logs
  "$BIN/omarchy-clip" copy -t image/png <"$T/img.png"
  check "Image copy ships PNG as base64 on PowerShell stdin (not argv)" \
    bash -c "base64 -d '$(ps_last_stdin)' | cmp -s - '$T/img.png'"
  check "Image copy keeps a lossless 'PNG' clipboard format" grep -q 'SetData("PNG"' "$(ps_last)"
  pwsh_check "Clipboard PowerShell scripts parse (pwsh)" "$(ps_last)"

  check "SSH session without interop selects OSC 52" \
    test "$(SSH_CONNECTION='1 2 3 4' OMW_FORCE_INTEROP='' OMW_FORCE_WSL='' "$BIN/omarchy-clip" backend copy)" = "osc52"
  check "SSH session inside tmux selects tmux" \
    test "$(TMUX=/tmp/x,1,0 SSH_CONNECTION='1 2 3 4' OMW_FORCE_INTEROP='' OMW_FORCE_WSL='' "$BIN/omarchy-clip" backend copy)" = "tmux"

  : >"$T/tty"
  printf 'secret' | OMARCHY_CLIP_TTY="$T/tty" "$BIN/omarchy-clip" osc52
  check "OSC 52 emits ESC]52;c;<base64>BEL" test "$(cat "$T/tty")" = $'\e]52;c;'"$(printf secret | base64 -w0)"$'\a'
  : >"$T/tty"
  printf 'x' | TMUX=/tmp/x,1,0 OMARCHY_CLIP_TTY="$T/tty" "$BIN/omarchy-clip" osc52
  check "OSC 52 inside tmux is DCS-wrapped with doubled ESC" bash -c "[[ \"\$(cat '$T/tty')\" == \$'\\ePtmux;\\e\\e]52;c;'* ]]"
  check "Oversized OSC 52 payload is refused, not truncated" \
    bash -c "! head -c 200000 /dev/zero | OMARCHY_CLIP_TTY='$T/tty' '$BIN/omarchy-clip' osc52 2>/dev/null"
  check "OSC 52 paste (clipboard read) is refused" \
    bash -c "! OMARCHY_CLIP_BACKEND=osc52 '$BIN/omarchy-clip' paste 2>/dev/null"
  check "Unknown MIME type rejected" bash -c "! '$BIN/omarchy-clip' copy -t application/x-evil </dev/null 2>/dev/null"

  # Headless (no controlling tty, no SSH_TTY): OSC 52 must never land on stdout.
  local out rc
  out=$(printf 'secret' | env -u SSH_TTY -u OMARCHY_CLIP_TTY OMARCHY_CLIP_BACKEND=osc52 \
        setsid -w "$BIN/omarchy-clip" copy 2>"$T/clip.err"); rc=$?
  check "No tty: OSC 52 copy exits 3" test "$rc" -eq 3
  check "No tty: nothing is written to stdout (no escape-sequence pollution)" test -z "$out"
  check "No tty: the failure is explained on stderr" grep -q 'No terminal' "$T/clip.err"
  out=$(printf 'secret' | env -u SSH_TTY -u OMARCHY_CLIP_TTY setsid -w "$BIN/omarchy-clip" osc52 2>/dev/null); rc=$?
  check "No tty: 'omarchy-clip osc52' behaves the same" bash -c "[[ $rc -eq 3 && -z \"\$1\" ]]" _ "$out"
}

# =============================================================================
# 4. omarchy-sync-dirs
# =============================================================================
test_sync_dirs() {
  header "4. omarchy-sync-dirs (Known Folder symlinks)"
  reset_logs
  printf 'Downloads\tC:\\Users\\Jane Doe\\Downloads\nDesktop\tC:\\Users\\Jane Doe\\OneDrive\\Desktop\nDocuments\tD:\\Docs\nPictures\t\\\\server\\share\\pics\n' >"$T/ps_folders.out"
  export FAKE_PS_OUT="$T/ps_folders.out"
  "$BIN/omarchy-sync-dirs" --dirs "Downloads Desktop Documents Pictures" >/dev/null 2>"$T/sync.err"
  check "Downloads -> real Known Folder path" test "$(readlink "$HOME/win/Downloads")" = "$WINHOME/Downloads"
  check "OneDrive-redirected Desktop resolved (not C:\\Users\\x\\Desktop)" test "$(readlink "$HOME/win/Desktop")" = "$WINHOME/OneDrive/Desktop"
  check "Documents relocated to D: is followed" test "$(readlink "$HOME/win/Documents")" = "$MNT/d/Docs"
  check "OneDrive hydration warning emitted" grep -q 'OneDrive' "$T/sync.err"
  check "Network-share Known Folder skipped" test ! -e "$HOME/win/Pictures"
  check "Performance boundary note written" test -f "$HOME/win/.omarchy-boundary"
  check "Resolution uses the shell API (GetFolderPath + shell:Downloads)" \
    bash -c "grep -q 'GetFolderPath(\"MyDocuments\")' '$(ps_last)' && grep -q 'shell:Downloads' '$(ps_last)'"
  pwsh_check "Known Folder PowerShell parses (pwsh)" "$(ps_last)"

  check "Second run is idempotent" bash -c "'$BIN/omarchy-sync-dirs' 2>&1 | grep -q 'up to date'"

  rm -f "$HOME/win/Documents"; mkdir -p "$HOME/win/Documents"; echo keep >"$HOME/win/Documents/mine.txt"
  ln -sfn /opt "$HOME/win/Desktop"
  "$BIN/omarchy-sync-dirs" >/dev/null 2>&1
  check "Real directory at ~/win/Documents is never replaced" test -f "$HOME/win/Documents/mine.txt"
  check "User symlink outside DrvFs is preserved without --force" test "$(readlink "$HOME/win/Desktop")" = "/opt"
  "$BIN/omarchy-sync-dirs" --force >/dev/null 2>&1
  check "--force re-points a foreign symlink" test "$(readlink "$HOME/win/Desktop")" = "$WINHOME/OneDrive/Desktop"

  "$BIN/omarchy-sync-dirs" --remove >/dev/null 2>&1
  check "--remove deletes managed symlinks" test ! -L "$HOME/win/Downloads"
  check "--remove keeps real user directories" test -f "$HOME/win/Documents/mine.txt"
  rm -rf "$HOME/win"
  "$BIN/omarchy-sync-dirs" --dry-run >/dev/null 2>&1
  check "--dry-run touches nothing" test ! -e "$HOME/win"
  unset FAKE_PS_OUT
}

# =============================================================================
# 5. DrvFs guard
# =============================================================================
test_drvfs_guard() {
  header "5. DrvFs Performance Boundary Guard"
  mkdir -p "$MNT/c/proj" "$T/guardbin"
  printf '#!/bin/sh\necho ran-$(basename "$0")\n' >"$T/guardbin/cargo"; chmod +x "$T/guardbin/cargo"
  cp "$T/guardbin/cargo" "$T/guardbin/git"
  ln -sfn "$MNT/c/proj" "$T/home/winproj"
  local guard="$ROOT_DIR/wsl/lib/drvfs-guard.sh"
  check "cargo on a Windows drive is blocked" bash -c "[[ \"\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' bash --norc --noprofile -i -c \"source '$guard'; cd '$MNT/c/proj'; cargo build\" 2>&1)\" == *refusing* ]]"
  check "Blocked build returns non-zero" bash -c "! PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' bash --norc --noprofile -i -c \"source '$guard'; cd '$MNT/c/proj'; cargo build\" >/dev/null 2>&1"
  check "Symlinked path (~/winproj -> /mnt/c) resolved physically and blocked" \
    bash -c "[[ \"\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' HOME='$T/home' bash --norc --noprofile -i -c \"source '$guard'; cd '$T/home/winproj'; cargo build\" 2>&1)\" == *refusing* ]]"
  check "OMARCHY_DRVFS_GUARD=off bypasses" bash -c "[[ \"\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' OMARCHY_DRVFS_GUARD=off bash --norc --noprofile -i -c \"source '$guard'; cd '$MNT/c/proj'; cargo build\" 2>&1)\" == *ran-cargo* ]]"
  check "git warns but still runs" bash -c "out=\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' bash --norc --noprofile -i -c \"source '$guard'; cd '$MNT/c/proj'; git status\" 2>&1); [[ \$out == *slow* && \$out == *ran-git* ]]"
  check "Builds on ext4 are untouched" bash -c "[[ \"\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' bash --norc --noprofile -i -c \"source '$guard'; cd '$T/home'; cargo build\" 2>&1)\" == *ran-cargo* ]]"
  check "Existing user function is never shadowed" bash -c "[[ \"\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' bash --norc --noprofile -i -c \"cargo() { echo mine; }; source '$guard'; cd '$MNT/c/proj'; cargo\" 2>&1)\" == *mine* ]]"
  check "Non-interactive shells are not wrapped" bash -c "[[ \"\$(PATH='$T/guardbin:$PATH' OMARCHY_DRVFS_ROOT='$MNT' bash --norc --noprofile -c \"source '$guard'; cd '$MNT/c/proj'; cargo\" 2>&1)\" == ran-cargo ]]"
}

# =============================================================================
# 6. SSH agent bridge (end-to-end through a real ssh-agent)
# =============================================================================
test_ssh_agent_bridge() {
  header "6. omarchy-ssh-agent-bridge (npiperelay + socat)"
  if ! command -v socat >/dev/null || ! command -v ssh-agent >/dev/null; then
    skip "socat/ssh-agent unavailable"
    return
  fi
  local real="$T/real-agent.sock" relay="$WINHOME/AppData/Local/omarchy/bin/npiperelay.exe"
  eval "$(ssh-agent -a "$real" -s)" >/dev/null
  BG_PIDS+=("$SSH_AGENT_PID")
  ssh-keygen -q -t ed25519 -N '' -C 'omarchy-test-key' -f "$T/id_test" >/dev/null
  SSH_AUTH_SOCK="$real" ssh-add -q "$T/id_test" 2>/dev/null
  unset SSH_AUTH_SOCK SSH_AGENT_PID
  # Stand-in for npiperelay.exe: records argv, then splices stdio to the real agent.
  mkdir -p "$(dirname "$relay")"
  cat >"$relay" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$LOG/npiperelay.argv"
exec socat STDIO UNIX-CONNECT:$real
EOF
  chmod +x "$relay"

  local b="$WSLBIN/omarchy-ssh-agent-bridge" sock="$T/run/ssh-agent.sock"
  "$b" start --quiet >/dev/null 2>&1
  check "Bridge socket created at \$XDG_RUNTIME_DIR/ssh-agent.sock" test -S "$sock"
  check "Socket is private to the user (0600)" test "$(stat -c %a "$sock")" = "600"
  check "Key held by the 'Windows' agent is listed through the bridge" \
    bash -c "SSH_AUTH_SOCK='$sock' ssh-add -l | grep -q omarchy-test-key"
  check "Relay found in a profile path containing spaces (Jane Doe)" grep -qx -- '-ei' "$LOG/npiperelay.argv"
  check "Relay targets //./pipe/openssh-ssh-agent" grep -qx '//./pipe/openssh-ssh-agent' "$LOG/npiperelay.argv"
  check "env prints an export for the live bridge" bash -c "[[ \"\$('$b' env)\" == \"export SSH_AUTH_SOCK=$sock\" ]]"
  check "start is idempotent" bash -c "'$b' start 2>&1 | grep -q 'already running'"
  check "profile.d exports SSH_AUTH_SOCK for the live bridge socket" \
    test "$(env -i HOME="$HOME" XDG_RUNTIME_DIR="$T/run" PATH=/usr/bin:/bin sh -c ". '$ROOT_DIR/wsl/profile.d/30-omarchy-ssh-agent.sh'; echo \"\$SSH_AUTH_SOCK\"")" = "$sock"
  "$b" enable >/dev/null 2>&1
  check "enable writes environment.d SSH_AUTH_SOCK for systemd user services" \
    grep -qx "SSH_AUTH_SOCK=$sock" "$XDG_CONFIG_HOME/environment.d/30-omarchy-ssh-agent.conf"
  "$b" disable >/dev/null 2>&1
  check "disable removes the environment.d entry" test ! -e "$XDG_CONFIG_HOME/environment.d/30-omarchy-ssh-agent.conf"
  check "Signing works without the private key in WSL" \
    bash -c "rm -f '$T/id_test'; echo data >'$T/msg'; SSH_AUTH_SOCK='$sock' ssh-keygen -Y sign -f '$T/id_test.pub' -n file '$T/msg' >/dev/null 2>&1 && test -s '$T/msg.sig'"
  "$b" stop >/dev/null 2>&1
  check "stop tears the relay down" bash -c "! SSH_AUTH_SOCK='$sock' ssh-add -l >/dev/null 2>&1"

  # A foreign live agent on the same path must never be clobbered.
  local other_pid
  eval "$(ssh-agent -a "$sock" -s)" >/dev/null; other_pid=$SSH_AGENT_PID; unset SSH_AUTH_SOCK SSH_AGENT_PID
  BG_PIDS+=("$other_pid")
  check "Refuses to replace a different live agent's socket" bash -c "! '$b' start >/dev/null 2>&1"
  kill "$other_pid" 2>/dev/null; sleep 0.2; rm -f "$sock"

  check "Pipe names with path traversal are rejected" bash -c "! '$b' start --pipe '../../evil' >/dev/null 2>&1"
  mkdir -p "$WINHOME/.ssh"
  printf 'IdentityAgent "\\\\.\\pipe\\pageant.jane.0a1b2c3d"\r\n' >"$WINHOME/.ssh/pageant.conf"
  "$b" start --pageant --quiet >/dev/null 2>&1
  check "--pageant reads the pipe from pageant.conf" grep -q '//./pipe/pageant.jane.0a1b2c3d' "$T/run/omarchy/ssh-agent-relay.sh"
  "$b" stop >/dev/null 2>&1

  # Regression: a client still connected during `stop` used to keep the start
  # lock (fd 9 leaked into socat's per-connection children), so the next
  # `start` printed "in progress", returned 0 and left no bridge running.
  local rc client spid
  "$b" start --quiet >/dev/null 2>&1
  spid=$(cat "$T/run/omarchy/ssh-agent-bridge.pid" 2>/dev/null)
  check "Lock fd is not inherited by socat" bash -c "! ls -l /proc/$spid/fd 2>/dev/null | grep -q ssh-agent-bridge.lock"
  python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(30)' "$sock" &
  client=$!; BG_PIDS+=("$client"); sleep 0.5
  # "[/]" keeps pgrep -f from matching the checking shell's own command line.
  local relay_re="UNIX-CONNECT:[/]${real#/}"
  check "Live client connection spawned a relay" bash -c "pgrep -f '$relay_re' >/dev/null"
  "$b" stop >/dev/null 2>&1; sleep 0.3
  check "stop also kills per-connection relays (process group)" bash -c "! pgrep -f '$relay_re' >/dev/null"
  rc=0; "$b" start --quiet >/dev/null 2>&1 || rc=$?
  check "start after stop with a client connected exits 0" test "$rc" -eq 0
  check "... and the bridge is really running again" bash -c "'$b' status | grep -q '^bridge:  running'"
  check "... and serves the Windows agent" bash -c "SSH_AUTH_SOCK='$sock' ssh-add -l | grep -q omarchy-test-key"
  kill "$client" 2>/dev/null
  "$b" stop >/dev/null 2>&1
  exec 8>"$T/run/omarchy/ssh-agent-bridge.lock"
  flock -n 8
  rc=0; "$b" start --quiet >/dev/null 2>&1 || rc=$?
  check "A held start lock is a failure (exit 75), not silent success" test "$rc" -eq 75
  exec 8>&-
  "$b" stop >/dev/null 2>&1
}

# =============================================================================
# 6b. GPG bridge
# =============================================================================
test_gpg_bridge() {
  header "6b. GPG bridge (Gpg4win) never kills a live gpg-agent silently"
  if ! have gpgconf || ! have gpg-agent || ! have gpg-connect-agent || ! have socat; then
    skip "gnupg/socat unavailable"
    return
  fi
  local b="$WSLBIN/omarchy-ssh-agent-bridge" gh="$T/gnupg" wg="$MNT/c/Program Files (x86)/GnuPG/bin" rc out
  mkdir -p "$gh" "$wg" && chmod 0700 "$gh"
  printf 'no-autostart\n' >"$gh/gpg.conf"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'C:\\\\Users\\\\Jane Doe\\\\AppData\\\\Local\\\\gnupg\\\\S.gpg-agent\\r\\n'" >"$wg/gpgconf.exe"
  chmod +x "$wg/gpgconf.exe"
  GNUPGHOME="$gh" gpgconf --launch gpg-agent
  rc=0; out=$(GNUPGHOME="$gh" "$b" gpg-start 2>&1) || rc=$?
  check "gpg-start refuses while a Linux gpg-agent is running" test "$rc" -ne 0
  check "... and says how to proceed (--replace)" grep -q -- '--replace' <<<"$out"
  check "... and the user's agent is still alive" bash -c "GNUPGHOME='$gh' gpg-connect-agent --no-autostart /bye >/dev/null 2>&1"
  rc=0; out=$(GNUPGHOME="$gh" "$b" gpg-start --replace 2>&1) || rc=$?
  check "gpg-start --replace stops the agent with a warning and bridges" \
    bash -c "[[ $rc -eq 0 && \"\$1\" == *'Stopping the running Linux gpg-agent'* ]]" _ "$out"
  check "Bridge now owns the agent socket" \
    bash -c "[[ -S \"\$(GNUPGHOME='$gh' gpgconf --list-dirs agent-socket)\" ]] && grep -qa socat /proc/\$(cat '$T/run/omarchy/gpg-agent-bridge.pid')/cmdline"
  GNUPGHOME="$gh" "$b" gpg-stop >/dev/null 2>&1
  check "gpg-stop stops the gpg bridge" test ! -e "$T/run/omarchy/gpg-agent-bridge.pid"
  GNUPGHOME="$gh" gpgconf --kill gpg-agent 2>/dev/null || true
}

# =============================================================================
# 7. Git credential bridge
# =============================================================================
test_git_credential_bridge() {
  header "7. omarchy-git-credential-bridge (GCM -> gh fallback)"
  local g="$WSLBIN/omarchy-git-credential-bridge" gcm="$T/gcm/git-credential-manager.exe" out
  mkdir -p "$T/gcm"
  cat >"$gcm" <<EOF
#!/usr/bin/env bash
{ echo "action=\$1"; echo "WSLENV=\${WSLENV:-}"; echo "GCM_INTERACTIVE=\${GCM_INTERACTIVE:-}"; cat; } >>"$LOG/gcm.log"
[[ "\$1" == get ]] && printf 'protocol=https\r\nhost=github.com\r\nusername=jane\r\npassword=gho_FAKE\r\n'
exit 0
EOF
  chmod +x "$gcm"
  reset_logs
  out=$(printf 'protocol=https\nhost=github.com\n\n' | OMARCHY_GCM="$gcm" "$g" get)
  check "GCM credential is returned to git" bash -c "[[ \"$out\" == *password=gho_FAKE* ]]"
  check "Output contains no CR (defensive: CR would corrupt the password)" bash -c "! printf '%s' \"$out\" | grep -q \$'\\r'"
  check "GIT_EXEC_PATH is shared to GCM through WSLENV (/wp)" grep -q 'WSLENV=.*GIT_EXEC_PATH/wp' "$LOG/gcm.log"
  reset_logs
  printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 OMARCHY_GCM="$gcm" "$g" get >/dev/null
  check "GIT_TERMINAL_PROMPT=0 becomes GCM_INTERACTIVE=never on Windows" \
    bash -c "grep -q 'GCM_INTERACTIVE=never' '$LOG/gcm.log' && grep -q 'WSLENV=.*GCM_INTERACTIVE' '$LOG/gcm.log'"

  printf '#!/usr/bin/env bash\n[[ "$*" == "auth git-credential get" ]] && printf "protocol=https\\nhost=github.com\\nusername=x-access-token\\npassword=gh_FALLBACK\\n"\nexit 0\n' >"$T/fakebin/gh"
  chmod +x "$T/fakebin/gh"
  out=$(printf 'protocol=https\nhost=github.com\n\n' | PATH="$T/fakebin:$PATH" OMARCHY_GCM="$T/nonexistent" "$g" get)
  check "Falls back to gh auth git-credential when GCM is absent" bash -c "[[ \"$out\" == *password=gh_FALLBACK* ]]"
  out=$(printf 'protocol=https\nhost=github.com\n\n' | PATH="/usr/bin:/bin" OMARCHY_GCM="$T/nonexistent" OMARCHY_GIT_CREDENTIAL_ORDER="gcm" "$g" get)
  check "No backend -> empty answer (git falls through to its prompt)" test -z "$out"

  reset_logs
  printf 'protocol=https\nhost=github.com\nusername=jane\npassword=old\n\n' | OMARCHY_GCM="$gcm" "$g" erase
  check "erase is forwarded to GCM (keeps the Windows vault in sync)" grep -q 'action=erase' "$LOG/gcm.log"
  reset_logs
  printf 'protocol=https\n$(touch %s/pwned)\n\n' "$T" | OMARCHY_GCM="$gcm" "$g" get >/dev/null 2>&1
  check "Malformed credential requests are not forwarded" bash -c "[[ ! -s '$LOG/gcm.log' && ! -e '$T/pwned' ]]"
  check "Unknown helper actions are ignored (gitcredentials(7))" bash -c "'$g' frobnicate </dev/null"

  local gcfg="$T/gitconfig"
  printf '[credential]\n\thelper = store\n' >"$gcfg"
  # Run git outside any repository (a worktree's .git file may point outside
  # the container and make every git call fail).
  (cd "$T" && GIT_CONFIG_GLOBAL="$gcfg" OMARCHY_GCM="$gcm" "$g" install >/dev/null 2>&1)
  out=$(cd "$T" && GIT_CONFIG_GLOBAL="$gcfg" git config --global --get-all credential.helper | paste -sd'|' -)
  check "install resets inherited helpers then adds the bridge" test "$out" = "|/usr/lib/omarchy-wsl/bin/omarchy-git-credential-bridge"
  check "install enables Azure Repos useHttpPath" test "$(cd "$T" && GIT_CONFIG_GLOBAL="$gcfg" git config --global credential.https://dev.azure.com.useHttpPath)" = "true"
  (cd "$T" && GIT_CONFIG_GLOBAL="$gcfg" "$g" uninstall >/dev/null 2>&1)
  check "uninstall restores the previous helper" test "$(cd "$T" && GIT_CONFIG_GLOBAL="$gcfg" git config --global --get-all credential.helper)" = "store"

  mkdir -p "$MNT/c/Program Files/Git/clangarm64/bin"
  cp "$gcm" "$MNT/c/Program Files/Git/clangarm64/bin/git-credential-manager.exe"
  rm -f "$T/run/omarchy/"cache-gcm-path*
  check "GCM discovered in the ARM64 Git for Windows layout (clangarm64)" \
    bash -c "'$g' status 2>/dev/null | grep -q 'clangarm64/bin/git-credential-manager.exe'"
  mkdir -p "$MNT/c/Program Files/Git/ucrt64/bin"
  cp "$gcm" "$MNT/c/Program Files/Git/ucrt64/bin/git-credential-manager.exe"
  rm -f "$T/run/omarchy/"cache-gcm-path*
  check "Git for Windows >= 2.56 ucrt64 layout preferred" \
    bash -c "'$g' status 2>/dev/null | grep -q 'ucrt64/bin/git-credential-manager.exe'"
  check "gh-token extracts the GCM github.com token" test "$(OMARCHY_GCM="$gcm" "$g" gh-token 2>/dev/null)" = "gho_FAKE"
}

# =============================================================================
# 7b. wsl-shims-setup.sh
# =============================================================================
test_shims_setup() {
  header "7b. wsl-shims-setup.sh (curated Windows shims)"
  local s="$WSLBIN/wsl-shims-setup.sh" sd="$T/shims" wa="$WINHOME/AppData/Local/Microsoft/WindowsApps"
  local pub="$MNT/c/Users/Public" gitd="$MNT/c/Program Files/Git" out
  mkdir -p "$wa" "$pub/AppData/Local/Microsoft/WindowsApps" "$gitd/ucrt64/bin" "$gitd/clangarm64/bin"
  # App Execution Aliases are NTFS reparse points: present (-e) but not regular
  # files on DrvFs. A FIFO reproduces "exists, not -f, not -x" on Linux.
  rm -f "$wa/wt.exe" && mkfifo "$wa/wt.exe"
  printf '#!/bin/sh\n' | tee "$pub/AppData/Local/Microsoft/WindowsApps/wt.exe" "$pub/wt.exe" >/dev/null
  chmod +x "$pub/AppData/Local/Microsoft/WindowsApps/wt.exe" "$pub/wt.exe"
  for d in ucrt64 clangarm64; do
    printf '#!/bin/sh\n' >"$gitd/$d/bin/git-credential-manager.exe"; chmod +x "$gitd/$d/bin/git-credential-manager.exe"
  done
  rm -rf "$sd"; reset_logs
  OMARCHY_SHIMS_DIR="$sd" "$s" >/dev/null 2>&1
  check "wt.exe resolved via %LOCALAPPDATA%\\Microsoft\\WindowsApps (depth 6)" test "$(readlink "$sd/wt.exe")" = "$wa/wt.exe"
  check "App Execution Alias accepted although not a regular file" test -p "$(readlink "$sd/wt.exe")"
  check "Nothing is ever linked from C:\\Users\\Public" bash -c "! find '$sd' -type l -lname '*/Users/Public/*' | grep -q ."
  check "GCM: Git for Windows ucrt64 preferred" test "$(readlink "$sd/git-credential-manager.exe")" = "$gitd/ucrt64/bin/git-credential-manager.exe"
  check "powershell.exe / cmd.exe shims point into System32" \
    bash -c "[[ \$(readlink '$sd/powershell.exe') == '$SYS32/WindowsPowerShell/v1.0/powershell.exe' && \$(readlink '$sd/cmd.exe') == '$SYS32/cmd.exe' ]]"
  mv "$gitd/ucrt64" "$gitd/ucrt64.off"
  rm -rf "$sd"; OMARCHY_SHIMS_DIR="$sd" "$s" >/dev/null 2>&1
  check "GCM: ARM64 clangarm64 layout found" test "$(readlink "$sd/git-credential-manager.exe")" = "$gitd/clangarm64/bin/git-credential-manager.exe"
  mv "$gitd/ucrt64.off" "$gitd/ucrt64"

  # Interop down: cmd.exe cannot answer, so the depth-6 search is used, and it
  # never guesses between two Windows profiles.
  mv "$SYS32/cmd.exe" "$SYS32/cmd.exe.real"
  printf '#!/bin/sh\nexit 1\n' >"$SYS32/cmd.exe"; chmod +x "$SYS32/cmd.exe"
  rm -rf "$sd"; reset_logs
  OMARCHY_SHIMS_DIR="$sd" "$s" >/dev/null 2>&1
  check "No interop: the single per-user alias is found at depth 6" test "$(readlink "$sd/wt.exe")" = "$wa/wt.exe"
  mkdir -p "$MNT/c/Users/alice/AppData/Local/Microsoft/WindowsApps"
  : >"$MNT/c/Users/alice/AppData/Local/Microsoft/WindowsApps/wt.exe"
  rm -rf "$sd"; reset_logs
  OMARCHY_SHIMS_DIR="$sd" "$s" >/dev/null 2>"$T/shims.err"
  check "No interop + two profiles: no guess, a warning instead" bash -c "[[ ! -e '$sd/wt.exe' ]] && grep -q 'not guessing' '$T/shims.err'"
  rm -rf "$MNT/c/Users/alice"
  mv -f "$SYS32/cmd.exe.real" "$SYS32/cmd.exe"
  rm -rf "$sd"; reset_logs
  out=$(OMARCHY_SHIMS_DIR="$sd" "$s" --dry-run 2>/dev/null)
  check "--dry-run plans links and creates nothing" bash -c "[[ \"\$1\" == *'link $sd/wt.exe'* && ! -e '$sd' ]]" _ "$out"
}

# =============================================================================
# 8. omarchy-notify
# =============================================================================
test_notify() {
  header "8. omarchy-notify (Windows toast bridge)"
  local n="$BIN/omarchy-notify" evil=$'Build \'done\'; Remove-Item C:\\ -Recurse ‘x’ $(calc) <b>&' script
  script=$("$n" --print-script "$evil" "body")
  check "Title never appears verbatim in generated PowerShell" bash -c "! grep -qF 'Remove-Item' <<<\"\$1\"" _ "$script"
  check "Title travels as base64 and decodes losslessly" \
    bash -c "grep -o \"FromBase64String('[^']*')\" <<<\"\$1\" | head -1 | sed \"s/.*('\\(.*\\)')/\\1/\" | base64 -d | grep -qF \"\$2\"" _ "$script" "$evil"
  check "XML is escaped inside PowerShell (SecurityElement.Escape)" grep -q 'SecurityElement' <<<"$script"
  printf '%s\n' "$script" >"$T/toast.ps1"
  pwsh_check "Toast PowerShell parses (pwsh)" "$T/toast.ps1"

  reset_logs
  "$n" --sync -l success "Build finished" "cargo build" 2>/dev/null
  check "Toast delivered through WinRT ToastNotificationManager" grep -q 'ToastNotificationManager' "$(ps_last)"
  check "Tokyo Night icon mirrored to %LOCALAPPDATA%/Omarchy/notify" test -f "$WINHOME/AppData/Local/Omarchy/notify/omarchy-success.png"
  check "Success uses the default Windows sound event" grep -q 'Notification.Default' <(grep -o "FromBase64String('[^']*')" "$(ps_last)" | sed "s/.*('\(.*\)')/\1/" | while read -r b; do echo "$b" | base64 -d; echo; done)

  : >"$T/tty"
  SSH_TTY="$T/tty" "$n" --osc "Agent; done" "task;42"
  check "OSC 777 notify emitted with ';' stripped from fields" bash -c "grep -qF \$'\\e]777;notify;Agent, done;task,42' '$T/tty'"
  check "BEL emitted for Windows Terminal taskbar flash" grep -q $'\a' "$T/tty"

  check "--wrap preserves the wrapped command's exit status" bash -c "'$n' --wrap --min-seconds 999 -- sh -c 'exit 7'; [[ \$? -eq 7 ]]"
  reset_logs
  "$n" --wrap --sync --min-seconds 0 -- false 2>/dev/null
  check "--wrap failure raises an error toast with the Reminder sound" \
    bash -c "grep -o \"FromBase64String('[^']*')\" '$(ps_last)' | sed \"s/.*('\\(.*\\)')/\\1/\" | while read -r b; do echo \"\$b\" | base64 -d; echo; done | grep -q 'Notification.Reminder'"
  check "Invalid level rejected" bash -c "! '$n' -l critical x 2>/dev/null"
  check "Hostile AppUserModelID rejected" bash -c "! '$n' --app-id 'x\" ; calc' x 2>/dev/null"
  check "Generated icons are valid PNGs" bash -c "for f in '$ROOT_DIR'/assets/notify/*.png; do [[ \"\$(head -c8 \"\$f\" | od -An -tx1 | tr -d ' ')\" == 89504e470d0a1a0a ]] || exit 1; done"
}

# =============================================================================
# 9. Docker / Podman bridge
# =============================================================================
test_docker_bridge() {
  header "9. omarchy-docker-bridge (engine router)"
  if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
    skip "python3/curl unavailable"
    return
  fi
  local d="$BIN/omarchy-docker-bridge"
  export OMARCHY_WSL_SHARED_DIR="$T/wsl" OMARCHY_SYSTEM_DOCKER_SOCK="$T/no-system-docker.sock"
  mkdir -p "$T/wsl/docker-desktop/shared-sockets/guest-services" "$T/run/podman"
  python3 - "$T/wsl/docker-desktop/shared-sockets/guest-services/docker.sock" "$T/run/podman/podman.sock" <<'EOF' &
import os, socket, sys, threading
def serve(path, name):
    if os.path.exists(path): os.unlink(path)
    s = socket.socket(socket.AF_UNIX); s.bind(path); os.chmod(path, 0o600); s.listen(16)
    while True:
        c, _ = s.accept(); c.recv(65536)
        body = b"OK" if True else b""
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nServer: " + name.encode() + b"\r\nConnection: close\r\n\r\n" + body); c.close()
for p, n in zip(sys.argv[1:], ["desktop", "podman"]):
    threading.Thread(target=serve, args=(p, n), daemon=True).start()
threading.Event().wait()
EOF
  BG_PIDS+=($!)
  for _ in $(seq 50); do [[ -S "$T/run/podman/podman.sock" ]] && break; sleep 0.1; done

  local st; st=$("$d" status)
  check "Docker Desktop integration socket detected healthy" grep -q '^desktop *healthy' <<<"$st"
  check "Rootless Podman socket detected healthy" grep -q '^podman *healthy' <<<"$st"
  check "Absent engines reported unavailable" grep -q '^docker-rootless *unavailable' <<<"$st"
  check "env prints nothing before opt-in (docker contexts untouched)" test -z "$("$d" env)"

  "$d" use auto >/dev/null 2>&1
  check "auto prefers Docker Desktop when present" test "$(readlink "$T/run/omarchy/docker.sock")" = "$T/wsl/docker-desktop/shared-sockets/guest-services/docker.sock"
  "$d" use podman >/dev/null 2>&1
  check "use podman re-points the stable route" test "$(readlink "$T/run/omarchy/docker.sock")" = "$T/run/podman/podman.sock"
  check "Docker API reachable end-to-end through the route" \
    bash -c "curl -fsSi --unix-socket '$T/run/omarchy/docker.sock' http://localhost/_ping | grep -q 'Server: podman'"
  local env_out; env_out=$("$d" env)
  check "env exports DOCKER_HOST at the stable route" grep -qF "export DOCKER_HOST=unix://$T/run/omarchy/docker.sock" <<<"$env_out"
  check "Podman route disables Testcontainers Ryuk" grep -q 'TESTCONTAINERS_RYUK_DISABLED=true' <<<"$env_out"
  check "Unknown engine rejected" bash -c "! '$d' use bogus 2>/dev/null"

  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$T/sys-docker.sock"
  check "install-system refuses to replace a real /run/docker.sock" \
    bash -c "! OMARCHY_SYSTEM_DOCKER_SOCK='$T/sys-docker.sock' '$d' install-system --dry-run 2>/dev/null"
  check "install-system --dry-run plans a tmpfiles.d symlink" \
    bash -c "'$d' install-system --dry-run | grep -q '^write /etc/tmpfiles.d/omarchy-docker-sock.conf: L '"
  if have socat; then
    setsid socat "UNIX-LISTEN:$T/run/omarchy/relay-desktop.sock,fork" EXEC:/bin/cat </dev/null >/dev/null 2>&1 &
    local relay_pid=$! _i
    echo "$relay_pid" >"$T/run/omarchy/relay-desktop.pid"
    for _i in $(seq 30); do [[ -S "$T/run/omarchy/relay-desktop.sock" ]] && break; sleep 0.1; done
    "$d" off >/dev/null 2>&1
    sleep 0.3
    check "off also stops background relays (no orphan socat)" bash -c "! kill -0 $relay_pid 2>/dev/null"
  else
    skip "socat unavailable: relay cleanup check disabled"
    "$d" off >/dev/null 2>&1
  fi
  check "off removes the route and the preference" bash -c "[[ ! -e '$T/run/omarchy/docker.sock' && ! -e '$XDG_CONFIG_HOME/omarchy/docker-bridge.conf' ]]"
  unset OMARCHY_WSL_SHARED_DIR OMARCHY_SYSTEM_DOCKER_SOCK
}

# =============================================================================
# 10. Watch bridge
# =============================================================================
test_watch_bridge() {
  header "10. omarchy-watch-bridge (Windows edits -> Linux inotify)"
  local w="$BIN/omarchy-watch-bridge" f="$MNT/c/proj/src/app.ts" m1 m2 c1 c2
  mkdir -p "$MNT/c/proj/src" "$MNT/c/proj/node_modules/pkg"
  echo 'export const x = 1' >"$f"; echo 'x' >"$MNT/c/proj/node_modules/pkg/index.js"
  touch -d '2020-01-01 00:00:00' "$f"
  m1=$(stat -c %Y "$f"); c1=$(stat -c %Z "$f")
  sleep 1.1
  printf 'Changed\tC:\\proj\\src\\app.ts\n' | "$w" run "$MNT/c/proj" --events-from - 2>/dev/null
  m2=$(stat -c %Y "$f"); c2=$(stat -c %Z "$f")
  check "Replay changes ctime (metadata event generated)" test "$c2" -gt "$c1"
  check "Replay preserves mtime (Windows' timestamp stays authoritative)" test "$m2" -eq "$m1"
  check "Replay never modifies content" test "$(cat "$f")" = 'export const x = 1'

  local nm="$MNT/c/proj/node_modules/pkg/index.js" nc1
  nc1=$(stat -c %Z "$nm"); sleep 1.1
  printf 'Changed\tC:\\proj\\node_modules\\pkg\\index.js\n' | "$w" run "$MNT/c/proj" --events-from - 2>/dev/null
  check "node_modules events are excluded" test "$(stat -c %Z "$nm")" -eq "$nc1"

  local count
  count=$(printf 'Changed\tC:\\proj\\src\\app.ts\nChanged\tC:\\proj\\src\\app.ts\nChanged\tC:\\proj\\src\\app.ts\n' | \
    "$w" run "$MNT/c/proj" --events-from - --verbose 2>&1 | grep -c 'replayed')
  check "Burst of identical events is coalesced (echo/loop suppression)" test "$count" -eq 1
  count=$(printf 'Changed\tC:\\other\\x.ts\n' | "$w" run "$MNT/c/proj" --events-from - --verbose 2>&1 | grep -c 'replayed')
  check "Events outside the watched root are ignored" test "$count" -eq 0

  if command -v inotifywait >/dev/null; then
    rm -f "$T/inotify.log"
    inotifywait -m -q -e attrib,close_write --format '%e %f' "$MNT/c/proj/src" >"$T/inotify.log" 2>/dev/null &
    local ip=$!; BG_PIDS+=("$ip"); sleep 0.5
    printf 'Changed\tC:\\proj\\src\\app.ts\n' | "$w" run "$MNT/c/proj" --events-from - 2>/dev/null
    sleep 0.5; kill "$ip" 2>/dev/null
    check "Real inotify IN_ATTRIB delivered to a Linux watcher" grep -q '^ATTRIB app.ts' "$T/inotify.log"
    check "Real inotify IN_CLOSE_WRITE delivered (entr/inotifywait users)" grep -q 'CLOSE_WRITE.* app.ts\|CLOSE_WRITE,CLOSE app.ts' "$T/inotify.log"
  else
    skip "inotifywait not installed: live inotify check disabled"
  fi

  local dc1; dc1=$(stat -c %Z "$MNT/c/proj/src"); sleep 1.1
  printf 'Deleted\tC:\\proj\\src\\gone.ts\n' | "$w" run "$MNT/c/proj" --events-from - 2>/dev/null
  check "Deletion touches the parent directory so watchers rescan" test "$(stat -c %Z "$MNT/c/proj/src")" -gt "$dc1"

  check "check on ext4 reports native inotify" bash -c "'$w' check '$T/home' | grep -q 'native inotify'"
  check "env prints chokidar/watchpack polling and watchexec 500ms" \
    bash -c "out=\$('$w' env); [[ \$out == *CHOKIDAR_USEPOLLING=1* && \$out == *WATCHPACK_POLLING=true* && \$out == *'--poll 500ms'* ]]"

  printf '22 1 8:1 / / rw - ext4 /dev/sdc rw\n80 22 0:50 / %s/c rw - 9p C:\\134 rw,aname=drvfs\n' "$MNT" >"$T/mountinfo"
  reset_logs
  OMW_MOUNTINFO="$T/mountinfo" timeout 10 "$w" run "$MNT/c/proj" >/dev/null 2>&1
  check "Windows watcher uses Register-ObjectEvent (no WaitForChanged gaps)" grep -q 'Register-ObjectEvent' "$(ps_last)"
  check "Windows watcher uses the 64 KB maximum buffer" grep -q 'InternalBufferSize=65536' "$(ps_last)"
  pwsh_check "Watcher PowerShell parses (pwsh)" "$(ps_last)"
}

# =============================================================================
# 11. Power governor
# =============================================================================
test_power_governor() {
  header "11. omarchy-power-governor (battery / thermal aware -j)"
  local p="$BIN/omarchy-power-governor" ps="$T/power" out
  mk_supply() { rm -rf "$ps"; mkdir -p "$ps/ADP1" "$ps/BAT1"; echo Mains >"$ps/ADP1/type"; echo "$1" >"$ps/ADP1/online"
                echo Battery >"$ps/BAT1/type"; echo 1 >"$ps/BAT1/present"; echo "$2" >"$ps/BAT1/capacity"; echo "$3" >"$ps/BAT1/status"; }
  export OMW_POWER_SUPPLY_DIR="$ps" OMARCHY_POWER_NO_WINDOWS=1
  mk_supply 1 90 Charging
  check "AC power: -j8 stays -j8" test "$("$p" jobs 8)" = 8
  mk_supply 0 55 Discharging
  check "Battery: -j8 -> -j4" test "$("$p" jobs 8)" = 4
  mk_supply 0 15 Discharging
  check "Low battery (15%): -j8 -> -j2" test "$("$p" jobs 8)" = 2
  check "Never below one job" test "$("$p" jobs 1)" = 1
  check "OMARCHY_POWER_GOVERNOR=off disables scaling" test "$(OMARCHY_POWER_GOVERNOR=off "$p" jobs 8)" = 8
  check "Invalid job count rejected" bash -c "! '$p' jobs 0 2>/dev/null && ! '$p' jobs abc 2>/dev/null"
  out=$("$p" status --json)
  check "status --json is valid JSON" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["source"]=="battery" and d["battery"]==15' "$out"

  # Battery-less AC mini-PC: unused USB-C / UCSI supply nodes report online=0.
  rm -rf "$ps"; mkdir -p "$ps/ucsi-source-psy-USBC000:001" "$ps/ucsi-source-psy-USBC000:002" "$ps/usbc-pd"
  for d in "$ps"/ucsi-source-*; do echo USB >"$d/type"; echo 0 >"$d/online"; done
  echo USB_C >"$ps/usbc-pd/type"; echo 0 >"$ps/usbc-pd/online"
  check "AC mini-PC (USB-C nodes online=0, no battery): factor 100" test "$("$p" factor)" = 100
  check "AC mini-PC: -j8 stays -j8" test "$("$p" jobs 8)" = 8
  out=$("$p" status --json)
  check "AC mini-PC is reported as ac from sysfs" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["source"]=="ac" and d["signal"]=="sysfs"' "$out"
  mk_supply 0 55 Discharging
  check "Laptop discharging: battery factor 50" test "$("$p" factor)" = 50
  mk_supply 1 90 Charging
  check "Laptop charging: factor 100" test "$("$p" factor)" = 100
  mk_supply 0 90 Charging
  check "Battery 'Charging' wins over a lagging adapter node (online=0)" test "$("$p" factor)" = 100

  unset OMARCHY_POWER_NO_WINDOWS
  export OMW_POWER_SUPPLY_DIR="$T/empty-supply"; mkdir -p "$OMW_POWER_SUPPLY_DIR"
  reset_logs
  printf 'line=Offline\npct=80\nchg=High\nsaver=Off\n' >"$T/ps_power.out"
  check "x86 kernel without battery module: Windows fallback detects battery" test "$(FAKE_PS_OUT="$T/ps_power.out" "$p" jobs 8)" = 4
  check "Windows query is cached (no second PowerShell spawn)" bash -c "FAKE_PS_OUT='$T/ps_power.out' '$p' jobs 8 >/dev/null; [[ \$(find '$LOG' -name 'ps.*.ps1' | wc -l) -eq 1 ]]"
  pwsh_check "Power query PowerShell parses (pwsh)" "$(ps_last)"
  check "WMI filter keeps its quotes (Name='_Total')" grep -qF "Name='_Total'" "$(ps_last)"
  reset_logs; printf 'line=Online\npct=100\nchg=High\nsaver=On\n' >"$T/ps_power.out"
  check "Energy Saver on AC -> 25%" test "$(FAKE_PS_OUT="$T/ps_power.out" "$p" jobs 8)" = 2
  reset_logs; printf 'line=Online\nchg=High\noverlay_ac=961cc777-2547-4f9d-8174-7d86181b8a7a\n' >"$T/ps_power.out"
  check "'Best power efficiency' power mode caps at the battery level" test "$(FAKE_PS_OUT="$T/ps_power.out" "$p" jobs 8)" = 4
  reset_logs; printf 'line=Online\nchg=High\nperf_limit=50\n' >"$T/ps_power.out"
  check "Thermal/firmware performance limit 50% halves -j" test "$(FAKE_PS_OUT="$T/ps_power.out" "$p" jobs 8)" = 4
  reset_logs; printf 'line=Offline\nchg=NoSystemBattery\npct=100\n' >"$T/ps_power.out"
  check "Desktop (NoSystemBattery) is treated as AC" test "$(FAKE_PS_OUT="$T/ps_power.out" "$p" jobs 8)" = 8
  mk_supply 0 40 Discharging
  export OMW_POWER_SUPPLY_DIR="$ps"
  reset_logs; printf 'line=Online\nchg=NoSystemBattery\n' >"$T/ps_power.out"
  check "Windows NoSystemBattery overrides a sysfs battery reading" test "$(FAKE_PS_OUT="$T/ps_power.out" "$p" factor)" = 100
  export OMW_POWER_SUPPLY_DIR="$T/empty-supply"
  reset_logs
  FAKE_PS_RC=1 "$p" jobs 8 >/dev/null 2>&1; FAKE_PS_RC=1 "$p" jobs 8 >/dev/null 2>&1
  check "Failed Windows query is negative-cached (one PowerShell spawn for two calls)" test "$(ps_count)" -eq 1
  "$p" refresh >/dev/null 2>&1; FAKE_PS_RC=1 "$p" jobs 8 >/dev/null 2>&1
  check "refresh clears the negative cache" test "$(ps_count)" -eq 2
  reset_logs; printf 'line=Offline\npct=$(touch %s/pwned-power)\nsaver=On;reboot\n' "$T" >"$T/ps_power.out"
  FAKE_PS_OUT="$T/ps_power.out" "$p" status >/dev/null 2>&1
  check "Hostile PowerShell output is parsed, never evaluated" test ! -e "$T/pwned-power"

  mkdir -p "$XDG_CONFIG_HOME/omarchy"
  printf 'OMARCHY_POWER_BATTERY_PCT=75\nOMARCHY_POWER_LOW_PCT=$(touch %s/pwned-conf)\n' "$T" >"$XDG_CONFIG_HOME/omarchy/power-governor.conf"
  check "Config file honoured (battery 75%)" test "$(OMARCHY_POWER_GOVERNOR=battery "$p" jobs 8)" = 6
  check "Config file is parsed, never sourced" test ! -e "$T/pwned-conf"
  rm -f "$XDG_CONFIG_HOME/omarchy/power-governor.conf"

  out=$(OMARCHY_POWER_GOVERNOR=battery "$BIN/omarchy-build" --dry-run --jobs 8 make)
  check "omarchy-build honours an explicit -j even on battery" grep -qx 'jobs=8' <<<"$out"
  out=$(OMARCHY_POWER_GOVERNOR=battery "$BIN/omarchy-build" --dry-run cargo build)
  check "omarchy-build applies the governor to its computed -j" grep -q 'note=power governor' <<<"$out"
  out=$(OMARCHY_POWER_GOVERNOR=battery "$BIN/omarchy-build" --dry-run --no-power cargo build)
  check "omarchy-build --no-power skips the governor" bash -c "! grep -q 'note=' <<<\"\$1\"" _ "$out"
  out=$("$BIN/omarchy-build" --dry-run --notify --no-power true)
  check "omarchy-build --notify wraps the command with omarchy-notify" grep -q 'omarchy-notify --wrap' <<<"$out"
  unset OMW_POWER_SUPPLY_DIR
}

# =============================================================================
# 12. Configuration artefacts
# =============================================================================
test_configs() {
  header "12. Audio, Registry, systemd & Packaging Artefacts"
  local pulse="$ROOT_DIR/wsl/etc/pulse/client.conf.d/wslg.conf"
  check "PulseAudio client pinned to WSLg server" grep -q '^default-server = unix:/mnt/wslg/PulseServer' "$pulse"
  check "Local PulseAudio autospawn disabled" grep -q '^autospawn = no' "$pulse"
  check "environment.d exports PULSE_SERVER for systemd --user services" grep -q '^PULSE_SERVER=unix:/mnt/wslg/PulseServer' "$ROOT_DIR/wsl/environment.d/50-omarchy-wslg.conf"
  check "User tmpfiles restore WSLg sockets without clobbering (L, not L+)" \
    bash -c "grep -q '^L %t/pulse' '$ROOT_DIR/wsl/tmpfiles.d/user/omarchy-wslg.conf' && ! grep -q '^L+' '$ROOT_DIR/wsl/tmpfiles.d/user/omarchy-wslg.conf'"
  check "ALSA default routed to the pulse plugin" grep -q 'type pulse' "$ROOT_DIR/wsl/etc/alsa/conf.d/99-omarchy-wslg-pulse.conf"

  local reg="$ROOT_DIR/tools/register-explorer-context-menu.reg"
  check ".reg file declares Registry Editor 5.00" bash -c "head -1 '$reg' | grep -q '^Windows Registry Editor Version 5.00'"
  check ".reg file is per-user only (no HKLM)" bash -c "! grep -q HKEY_LOCAL_MACHINE '$reg' '$ROOT_DIR/tools/unregister-explorer-context-menu.reg' '$ROOT_DIR/tools/register-explorer-context-menu.ps1'"
  # Verb commands are REG_EXPAND_SZ, written as hex(2) UTF-16LE bytes.
  local verbs
  verbs=$(python3 - "$reg" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8-sig").read().replace("\\\n", "")
for m in re.finditer(r'^@=hex\(2\):([0-9a-fA-F,\s]+)$', text, re.M):
    raw = bytes(int(b, 16) for b in m.group(1).replace(" ", "").split(",") if b)
    print(raw.decode("utf-16-le").rstrip("\x00"))
PY
)
  check "All three verbs use \"%V.\" (drive-root quote bug avoided)" test "$(grep -cF -- '-d "%V."' <<<"$verbs")" -eq 3
  check "Verbs run wt.exe by its absolute App Execution Alias path" \
    test "$(grep -c '^"%LOCALAPPDATA%\\Microsoft\\WindowsApps\\wt.exe" ' <<<"$verbs")" -eq 3
  check "Unregister removes exactly the registered keys" \
    test "$(grep -c '^\[-HKEY_CURRENT_USER.*OmarchyTerminal\]' "$ROOT_DIR/tools/unregister-explorer-context-menu.reg")" -eq 3
  check ".gitattributes forces CRLF for .reg files" grep -q '^\*\.reg text eol=crlf' "$ROOT_DIR/.gitattributes"
  check "PowerShell installer validates the distro name (anchored with \\z)" \
    grep -qF "ValidatePattern('^[A-Za-z0-9._-]{1,64}\z')" "$ROOT_DIR/tools/register-explorer-context-menu.ps1"
  check "Quick Access pin checks state first (pintohome toggles)" grep -q '679f85cb-0220-4080-b29b-5540cc05aab6' "$ROOT_DIR/tools/register-explorer-context-menu.ps1"

  check "SSH bridge user unit runs the bridge in the foreground" grep -q '^ExecStart=/usr/lib/omarchy-wsl/bin/omarchy-ssh-agent-bridge run' "$ROOT_DIR/wsl/systemd/user/omarchy-ssh-agent-bridge.service"
  local pkgs=("$ROOT_DIR"/packages/*.packages)
  check "Packages: socat (agent/docker relays)" grep -qx socat "${pkgs[@]}"
  check "Packages: wl-clipboard (WSLg clipboard backend)" grep -qx wl-clipboard "${pkgs[@]}"
  check "Packages: libpulse + alsa-plugins (WSLg audio client)" bash -c "grep -qx libpulse \"\$@\" && grep -qx alsa-plugins \"\$@\"" _ "${pkgs[@]}"
  local mf="$ROOT_DIR/rootfs.manifest" f bad=0
  for f in 'bin/omarchy-[*]' 'wsl/bin/[*]' lib/omarchy-wsl-interop.sh lib/omarchy-wsl-migration-gate lib/omarchy_theme \
           wsl/lib/drvfs-guard.sh 'wsl/profile.d/[*][.]sh' 'wsl/sysctl.d/[*][.]conf' 'wsl/systemd/[*][.]service' \
           'wsl/systemd/user/[*][.]service' wsl/cgroups/build.slice 'wsl/etc/pulse/client.conf.d/[*][.]conf'; do
    grep -Eq "^[a-z]+[[:space:]]+[a-z]+[[:space:]]+[0-7-]+[[:space:]]+${f}[[:space:]]" "$mf" || { bad=1; echo "      rootfs.manifest misses $f"; }
  done
  check "rootfs.manifest installs every integration artefact" test $bad -eq 0
  check "Integration doc exists and covers all 10 domains" \
    bash -c "[[ \$(grep -c '^## Domain [0-9]*' '$ROOT_DIR/docs/WINDOWS-INTEGRATION-QOL.md') -eq 10 ]]"
}

test_static
test_interop_lib
test_interop_fix
test_runtime_dir
test_open
test_clip
test_sync_dirs
test_drvfs_guard
test_ssh_agent_bridge
test_gpg_bridge
test_git_credential_bridge
test_shims_setup
test_notify
test_docker_bridge
test_watch_bridge
test_power_governor
test_configs

echo
echo "Windows Integration Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-0}" == 1 ]]; then exit 1; fi
exit 0
