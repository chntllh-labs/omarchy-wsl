#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Shared Windows Interop Library
# /usr/lib/omarchy-wsl/interop.sh
# ==============================================================================
# Sourced (never executed) by the Windows integration tools:
#   omarchy-open, omarchy-clip, omarchy-notify, omarchy-sync-dirs,
#   omarchy-docker-bridge, omarchy-watch-bridge, omarchy-power-governor,
#   omarchy-build, omarchy-ssh-agent-bridge, omarchy-git-credential-bridge,
#   omarchy-ca-sync, omarchy-dns-sync, omarchy-proxy-sync
#
# Design rules (see docs/WINDOWS-INTEGRATION-QOL.md):
# 1. Never rely on the Windows %PATH% (wsl.conf sets appendWindowsPath=false).
#    Every Windows binary is resolved to an absolute DrvFs path.
# 2. Never interpolate user data into cmd.exe command lines. PowerShell is only
#    ever invoked via -EncodedCommand, and user data travels as base64 or stdin.
# 3. One-shot PowerShell and cmd.exe calls made through this library are
#    bounded by a timeout (omw_ps_run: $OMW_TIMEOUT; omw_win_env: 5 s). Callers
#    that exec Windows binaries directly own their own timeout. Long-lived
#    relays (socat + npiperelay) are deliberately unbounded.
# 4. A stale $WSL_INTEROP (its wsl.exe session has exited) is repaired before
#    any Windows binary runs (omw_fix_interop).
#
# Test seams (used by the tests/ suites):
#   OMW_FORCE_WSL=1        treat the current kernel as WSL
#   OMW_FORCE_INTEROP=1    treat binfmt WSLInterop as enabled
#   OMW_MOUNT_ROOT=<dir>   DrvFs automount root (default: parsed from wsl.conf)
#   OMW_WSL_CONF=<file>    alternate /etc/wsl.conf
#   OMW_MOUNTINFO=<file>   alternate /proc/self/mountinfo
#   OMW_POWERSHELL=<exe>   explicit powershell.exe
#   OMW_PS_TRACE=<file>    append every PowerShell script (decoded) to <file>
#   OMW_WSL_RUN_DIR=<dir>  alternate /run/WSL (interop sockets)
#   OMW_PROC_NET_UNIX=<f>  alternate /proc/net/unix
# ==============================================================================

# Guard against double-sourcing.
[[ -n "${_OMW_INTEROP_LOADED:-}" ]] && return 0
_OMW_INTEROP_LOADED=1
_OMW_LIB_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

OMW_TAG="${OMW_TAG:-omarchy}"
OMW_TIMEOUT="${OMW_TIMEOUT:-15}"

# Colour only for a terminal, and never when NO_COLOR is set (no-color.org).
omw_color() { [[ -z "${NO_COLOR:-}" && -t 2 ]]; }
_omw_say() {
  local code="$1" label="$2"
  shift 2
  if omw_color; then
    printf '\e[%sm[%s]\e[0m %s\n' "$code" "$label" "$*" >&2
  else
    printf '[%s] %s\n' "$label" "$*" >&2
  fi
}
omw_log()  { [[ -n "${OMW_QUIET:-}" ]] || _omw_say 32 "${OMW_TAG}" "$*"; }
omw_warn() { _omw_say 33 "${OMW_TAG}:WARN" "$*"; }
omw_err()  { _omw_say 31 "${OMW_TAG}:ERROR" "$*"; }
omw_die()  { omw_err "$*"; exit 1; }

omw_have() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# 1. Environment Detection
# -----------------------------------------------------------------------------
omw_is_wsl() {
  [[ -n "${OMW_FORCE_WSL:-}" ]] && return 0
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  grep -qi 'microsoft' /proc/sys/kernel/osrelease 2>/dev/null
}

# WSL registers its PE loader as binfmt "WSLInterop" (or "WSLInterop-late" on
# newer builds that re-register after systemd-binfmt runs). If neither entry is
# enabled, executing any .exe fails with ENOEXEC.
omw_interop_enabled() {
  [[ -n "${OMW_FORCE_INTEROP:-}" ]] && return 0
  local entry
  for entry in /proc/sys/fs/binfmt_misc/WSLInterop /proc/sys/fs/binfmt_misc/WSLInterop-late; do
    if [[ -r "$entry" ]] && head -n 1 "$entry" 2>/dev/null | grep -q '^enabled'; then
      return 0
    fi
  done
  return 1
}

omw_distro_name() {
  echo "${WSL_DISTRO_NAME:-Omarchy}"
}

# -----------------------------------------------------------------------------
# 1b. Interop socket health ($WSL_INTEROP)
# -----------------------------------------------------------------------------
# Every wsl.exe session gets its own /run/WSL/<pid>_interop socket and exports
# its path as $WSL_INTEROP. When that session exits the socket file stays but
# nobody listens: tmux panes, nohup'd jobs and long-lived relays then fail every
# .exe launch even though binfmt says interop is "enabled". systemd services
# never get $WSL_INTEROP at all.

# _omw_socket_live <path>: 0 when a process accepts connections on the socket.
_omw_socket_live() {
  local sock="$1" netunix="${OMW_PROC_NET_UNIX:-/proc/net/unix}"
  [[ -S "$sock" ]] || return 1
  # Cheapest proof: a listening entry (flags __SO_ACCEPTCON) for this path.
  if [[ -r "$netunix" ]] && awk -v p="$sock" \
      '$NF == p && $4 == "00010000" { found = 1; exit } END { exit !found }' "$netunix" 2>/dev/null; then
    return 0
  fi
  # Otherwise a real connect(): ECONNREFUSED means the server is gone.
  if omw_have python3; then
    timeout 3 python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
except OSError:
    sys.exit(1)
s.close()' "$sock" 2>/dev/null
    return
  fi
  if omw_have socat; then
    timeout 3 socat -u OPEN:/dev/null "UNIX-CONNECT:${sock}" 2>/dev/null
    return
  fi
  return 1
}

# omw_fix_interop: make $WSL_INTEROP name a live interop socket. A stale or
# unset value is replaced by the newest live /run/WSL/*_interop socket and
# exported. Returns 1 when no usable socket exists ($WSL_INTEROP untouched).
# Exports only affect the calling shell: call it in the shell that execs the
# Windows binary (it is cheap and silent).
omw_fix_interop() {
  local current="${WSL_INTEROP:-}" run_dir="${OMW_WSL_RUN_DIR:-/run/WSL}" f
  # Per-process memo: one probe every 30 s at most for the same socket.
  if [[ -n "$current" && "$current" == "${_OMW_INTEROP_OK:-}" && -S "$current" ]] \
     && (( SECONDS - ${_OMW_INTEROP_OK_AT:-0} < 30 )); then
    return 0
  fi
  if [[ -n "$current" ]] && _omw_socket_live "$current"; then
    _OMW_INTEROP_OK="$current"
    _OMW_INTEROP_OK_AT=$SECONDS
    return 0
  fi
  [[ -d "$run_dir" ]] || return 1
  local -a cands=()
  for f in "$run_dir"/*_interop; do
    [[ -S "$f" && "$f" != "$current" ]] && cands+=("$f")
  done
  (( ${#cands[@]} )) || return 1
  while IFS= read -r f; do
    if _omw_socket_live "$f"; then
      export WSL_INTEROP="$f"
      _OMW_INTEROP_OK="$f"
      _OMW_INTEROP_OK_AT=$SECONDS
      return 0
    fi
  done < <(for f in "${cands[@]}"; do
             printf '%s\t%s\n' "$(stat -c %Y -- "$f" 2>/dev/null || echo 0)" "$f"
           done | sort -t "$(printf '\t')" -k1,1nr | cut -f2-)
  return 1
}

# omw_interop_ensure: policy wrapper used before launching a Windows binary.
# Fails only when $WSL_INTEROP is set, dead, and nothing can replace it (the
# .exe would fail anyway); an unset value is left to WSL's own fallback.
omw_interop_ensure() {
  omw_fix_interop && return 0
  [[ -n "${WSL_INTEROP:-}" && -z "${OMW_FORCE_INTEROP:-}" ]] || return 0
  omw_err "WSL interop socket ${WSL_INTEROP} is stale and no live session socket exists in ${OMW_WSL_RUN_DIR:-/run/WSL}. Open a new WSL window (or run 'wsl.exe -d $(omw_distro_name) --exec true' on Windows) and retry."
  return 1
}

# omw_interop_id: stable identity of the interop session in use ("none" when
# unknown). Keys caches whose answer depends on which Windows logon session
# launched WSL (USERPROFILE of an SSH service account vs the desktop user).
omw_interop_id() {
  local sock="${WSL_INTEROP:-}" id="none"
  if [[ -n "$sock" && -S "$sock" ]]; then
    id="${sock##*/}-$(stat -c %Y -- "$sock" 2>/dev/null || echo 0)"
  fi
  echo "${id//[^A-Za-z0-9_.-]/_}"
}

# DrvFs automount root, without trailing slash (default /mnt).
omw_mount_root() {
  if [[ -n "${OMW_MOUNT_ROOT:-}" ]]; then
    echo "${OMW_MOUNT_ROOT%/}"
    return
  fi
  local conf="${OMW_WSL_CONF:-/etc/wsl.conf}" root=""
  if [[ -r "$conf" ]]; then
    root=$(awk '
      /^[[:space:]]*\[/ { section = tolower($0); gsub(/[[:space:]\[\]]/, "", section); next }
      section == "automount" && /^[[:space:]]*root[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["[:space:]]/, ""); print; exit
      }' "$conf" 2>/dev/null)
  fi
  root="${root:-/mnt/}"
  echo "${root%/}"
}

# Windows directory (e.g. /mnt/c/Windows). Windows is not always on C:.
omw_system_root() {
  local root d
  root=$(omw_mount_root)
  for d in "$root"/c/Windows "$root"/[a-z]/Windows; do
    if [[ -d "$d/System32" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# 2. Windows Binary Resolution (no %PATH% lookups)
# -----------------------------------------------------------------------------
# omw_find_exe <name.exe> [extra absolute candidates...]
omw_find_exe() {
  local name="$1"
  shift
  local sysroot candidate
  sysroot=$(omw_system_root 2>/dev/null || true)
  local -a candidates=("$@")
  if [[ -n "$sysroot" ]]; then
    candidates+=(
      "$sysroot/System32/$name"
      "$sysroot/$name"
      "$sysroot/System32/WindowsPowerShell/v1.0/$name"
      "$sysroot/System32/OpenSSH/$name"
    )
  fi
  candidates+=("/usr/lib/omarchy-wsl/bin/$name")
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Windows PowerShell 5.1 is preferred over pwsh 7: it is always present, it
# defaults to an STA apartment (required by System.Windows.Forms.Clipboard), and
# it can load WinRT types (toasts, PowerManager) without extra assemblies.
omw_powershell() {
  if [[ -n "${OMW_POWERSHELL:-}" ]]; then
    echo "$OMW_POWERSHELL"
    return 0
  fi
  omw_find_exe powershell.exe
}

# -----------------------------------------------------------------------------
# 3. Safe PowerShell Execution
# -----------------------------------------------------------------------------
# Encode a script as base64(UTF-16LE) for -EncodedCommand. Base64 contains no
# quote, space, or metacharacter, so the Windows command line cannot be broken.
omw_ps_encode() {
  printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

# Encode arbitrary bytes as base64 for embedding inside a PowerShell script.
omw_b64() {
  printf '%s' "$1" | base64 -w0
}

# Preamble forcing BOM-less UTF-8 on both directions of the console pipe.
OMW_PS_PREAMBLE='$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";$__u=New-Object System.Text.UTF8Encoding $false;[Console]::OutputEncoding=$__u;[Console]::InputEncoding=$__u;'

# omw_ps_run [--stdin] <script>  — stdout is CR-stripped.
# stdin is /dev/null unless --stdin is given: a powershell.exe that inherits the
# terminal can swallow keystrokes meant for the shell, and one that inherits an
# idle pipe can block forever. Bounded by $OMW_TIMEOUT seconds (0 = unbounded,
# used only by the long-lived watcher).
omw_ps_run() {
  local stdin=0
  if [[ "${1:-}" == "--stdin" ]]; then
    stdin=1
    shift
  fi
  local script="$1" ps encoded
  ps=$(omw_powershell) || { omw_err "powershell.exe not found under $(omw_mount_root)"; return 127; }
  omw_interop_ensure || return 126
  encoded=$(omw_ps_encode "${OMW_PS_PREAMBLE}${script}")
  if [[ -n "${OMW_PS_TRACE:-}" ]]; then
    printf '%s\n' "${OMW_PS_PREAMBLE}${script}" >>"$OMW_PS_TRACE"
  fi
  # Run from a DrvFs cwd: Windows processes started from a \\wsl.localhost cwd
  # are slower, and cmd.exe-based helpers refuse UNC working directories.
  (
    cd "$(omw_system_root 2>/dev/null || echo /)" 2>/dev/null || true
    (( stdin )) || exec </dev/null
    timeout --kill-after=2 "$OMW_TIMEOUT" "$ps" -NoLogo -NoProfile -NonInteractive \
      -ExecutionPolicy Bypass -EncodedCommand "$encoded"
  ) | sed -u -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//'
  return "${PIPESTATUS[0]}"
}

# -----------------------------------------------------------------------------
# 4. Windows Environment Variables (cached; cmd.exe is ~10x faster than pwsh)
# -----------------------------------------------------------------------------
# omw_win_env <VAR>  — VAR must match ^[A-Za-z_][A-Za-z0-9_]*$ (never user data).
# Answers depend on the Windows logon session behind the interop socket, so the
# cache is keyed on that session (omw_interop_id) and lives OMW_WINENV_TTL
# seconds (default 300). Cached Windows paths are re-validated on every hit.
omw_win_env() {
  local var="$1" cached cmd value key
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  omw_fix_interop >/dev/null 2>&1 || true
  key="winenv-${var}-$(omw_interop_id)"
  if cached=$(omw_cache_get "$key" "${OMW_WINENV_TTL:-300}"); then
    if _omw_win_value_valid "$cached"; then
      echo "$cached"
      return 0
    fi
    omw_cache_del "$key"
  fi
  cmd=$(omw_find_exe cmd.exe) || return 127
  omw_interop_ensure || return 126
  value=$(
    cd "$(omw_system_root)" 2>/dev/null || exit 1
    timeout 5 "$cmd" /d /c "echo %${var}%" 2>/dev/null | tr -d '\r'
  ) || true
  # cmd echoes the literal token when the variable is undefined.
  if [[ -z "$value" || "$value" == "%${var}%" ]]; then
    return 1
  fi
  omw_cache_put "$key" "$value"
  echo "$value"
}

# A cached value that is a Windows drive path must still exist on DrvFs.
_omw_win_value_valid() {
  local v="$1" unix
  [[ "$v" =~ ^[A-Za-z]:[\\/] ]] || return 0
  unix=$(omw_win_to_unix "$v" 2>/dev/null) || return 1
  [[ -e "$unix" ]]
}

# -----------------------------------------------------------------------------
# 5. Path Translation
# -----------------------------------------------------------------------------
# Windows -> Linux. Handles X:\..., X:/..., and \\wsl.localhost\<distro>\...
omw_win_to_unix() {
  local p="$1" root drive rest
  root=$(omw_mount_root)
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    drive="${BASH_REMATCH[1],,}"
    rest="${BASH_REMATCH[2]:-/}"
    echo "${root}/${drive}${rest%/}"
    return 0
  fi
  if [[ "$p" =~ ^//(wsl\.localhost|wsl\$)/([^/]+)(/.*)?$ ]]; then
    if [[ "${BASH_REMATCH[2],,}" == "$(omw_distro_name | tr '[:upper:]' '[:lower:]')" ]]; then
      echo "${BASH_REMATCH[3]:-/}"
      return 0
    fi
  fi
  if omw_have wslpath; then
    wslpath -u "$1" 2>/dev/null && return 0
  fi
  return 1
}

# Linux -> Windows. DrvFs paths become X:\..., everything else becomes a
# \\wsl.localhost\<distro>\... UNC path.
omw_unix_to_win() {
  local p="$1" root abs
  root=$(omw_mount_root)
  abs=$(realpath -m -- "$p")
  if [[ "$abs" =~ ^${root}/([a-z])(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]^^}" rest="${BASH_REMATCH[2]:-/}"
    rest="${rest//\//\\}"
    echo "${drive}:${rest}"
    return 0
  fi
  if omw_have wslpath && [[ -z "${OMW_FORCE_WSL:-}" ]]; then
    wslpath -w "$abs" 2>/dev/null && return 0
  fi
  printf '%s\n' "\\\\wsl.localhost\\$(omw_distro_name)${abs//\//\\}"
}

# True if <path> lives on a Windows-backed filesystem (DrvFs over 9p/virtiofs).
omw_is_drvfs() {
  local abs mountinfo="${OMW_MOUNTINFO:-/proc/self/mountinfo}"
  abs=$(realpath -m -- "$1")
  [[ -r "$mountinfo" ]] || return 1
  awk -v target="$abs" '
    function unescape(s) { gsub(/\\040/, " ", s); return s }
    {
      mp = unescape($5)
      for (i = 7; i <= NF; i++) if ($i == "-") break
      fstype = $(i + 1); source = $(i + 2)
      if (target == mp || index(target, (mp == "/" ? "/" : mp "/")) == 1) {
        if (length(mp) >= bestlen) { bestlen = length(mp); bestfs = fstype; bestsrc = source }
      }
    }
    END {
      if (bestfs == "9p" || bestfs == "drvfs" || (bestfs == "virtiofs" && bestsrc ~ /^[A-Za-z]:/)) exit 0
      exit 1
    }' "$mountinfo"
}

# -----------------------------------------------------------------------------
# 6. Runtime Directory & TTL Cache
# -----------------------------------------------------------------------------
# _omw_owned_dir <dir>: a real directory (not a symlink) owned by the caller.
_omw_owned_dir() {
  [[ -d "$1" && ! -L "$1" ]] && [[ "$(stat -c %u -- "$1" 2>/dev/null)" == "$(id -u)" ]]
}

# _omw_private_dir <dir>: create (0700) or accept <dir>; refuse foreign or
# symlinked directories.
_omw_private_dir() {
  local d="$1"
  if [[ ! -e "$d" && ! -L "$d" ]]; then
    (umask 077 && mkdir -- "$d") 2>/dev/null || [[ -d "$d" ]] || return 1
  fi
  _omw_owned_dir "$d" || return 1
  chmod 0700 -- "$d" 2>/dev/null || true
}

# omw_runtime_dir: private per-user state directory for sockets, pid files,
# wrappers and caches.
#   1. $XDG_RUNTIME_DIR/omarchy when $XDG_RUNTIME_DIR is a real directory owned
#      by the user and not writable by group/others (systemd's /run/user/UID).
#   2. ${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/run, every component created
#      0700 and verified: refused when owned by someone else or a symlink.
# Never a predictable /tmp path another local user could pre-create.
omw_runtime_dir() {
  local base="${XDG_RUNTIME_DIR:-}" mode dir cache
  if [[ "$base" == /* ]] && _omw_owned_dir "$base" && [[ -w "$base" ]]; then
    mode=$(stat -c %a -- "$base" 2>/dev/null || echo 777)
    if (( (8#$mode & 8#022) == 0 )); then
      dir="$base/omarchy"
      if _omw_private_dir "$dir"; then
        echo "$dir"
        return 0
      fi
      omw_err "Runtime dir $dir is not a private directory owned by $(id -un); refusing to use it."
      return 1
    fi
  fi
  cache="${XDG_CACHE_HOME:-}"
  [[ "$cache" == /* ]] || cache="${HOME:+$HOME/.cache}"
  if [[ "$cache" != /* ]]; then
    omw_err "No usable runtime directory (XDG_RUNTIME_DIR and HOME unusable)."
    return 1
  fi
  for dir in "$cache" "$cache/omarchy" "$cache/omarchy/run"; do
    if ! _omw_private_dir "$dir"; then
      omw_err "Runtime dir component $dir is not a private directory owned by $(id -un); refusing to use it."
      return 1
    fi
  done
  echo "$cache/omarchy/run"
}

_omw_cache_file() {
  local dir
  dir=$(omw_runtime_dir 2>/dev/null) || return 1
  echo "$dir/cache-${1//[^A-Za-z0-9_.-]/_}"
}

# omw_cache_get <key> <ttl-seconds>
omw_cache_get() {
  local file now mtime
  file=$(_omw_cache_file "$1") || return 1
  [[ -f "$file" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  (( now - mtime <= $2 )) || return 1
  cat "$file"
}

# omw_cache_put <key> <value>
omw_cache_put() {
  local file
  file=$(_omw_cache_file "$1") || return 0
  printf '%s\n' "$2" >"${file}.$$" && mv -f "${file}.$$" "$file"
}

# omw_cache_del <key>
omw_cache_del() {
  local file
  file=$(_omw_cache_file "$1") || return 0
  rm -f -- "$file"
}

# omw_require_interop — exit with a precise diagnosis when interop is missing.
omw_require_interop() {
  omw_is_wsl || omw_die "Not running under WSL; Windows interop is unavailable."
  omw_interop_enabled || omw_die "WSL interop is disabled (binfmt WSLInterop missing). See /etc/binfmt.d/WSLInterop.conf and [interop] in /etc/wsl.conf."
  omw_interop_ensure || exit 1
}

# -----------------------------------------------------------------------------
# 7. Windows Profile & Named-Pipe Relay Helpers (npiperelay + socat)
# -----------------------------------------------------------------------------
# Linux path of %USERPROFILE% (e.g. /mnt/c/Users/Jane Doe).
omw_win_profile() {
  local up
  up=$(omw_win_env USERPROFILE) || return 1
  omw_win_to_unix "$up"
}

# npiperelay.exe (albertony fork: winget install albertony.npiperelay).
# x64-only builds; on Windows on ARM it runs under Prism emulation. Keeping it
# on a Windows drive avoids slow interop launches from the Linux filesystem.
omw_find_npiperelay() {
  local p profile root
  if [[ -n "${OMARCHY_NPIPERELAY:-}" ]]; then
    [[ -x "$OMARCHY_NPIPERELAY" ]] && { echo "$OMARCHY_NPIPERELAY"; return 0; }
    return 1
  fi
  if p=$(command -v npiperelay.exe 2>/dev/null); then echo "$p"; return 0; fi
  root=$(omw_mount_root)
  local -a candidates=("$root/c/ProgramData/chocolatey/bin/npiperelay.exe")
  if profile=$(omw_win_profile 2>/dev/null) && [[ -n "$profile" ]]; then
    candidates=(
      "$profile/AppData/Local/Microsoft/WinGet/Links/npiperelay.exe"
      "$profile/AppData/Local/omarchy/bin/npiperelay.exe"
      "$profile/scoop/shims/npiperelay.exe"
      "$profile/scoop/apps/npiperelay/current/npiperelay.exe"
      "$profile/go/bin/npiperelay.exe"
      "${candidates[@]}"
    )
  fi
  for p in "${candidates[@]}"; do
    [[ -f "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# socat's EXEC address splits on spaces with no quoting ("C:\Users\Jane Doe"
# breaks it). Write a 0700 wrapper holding the properly quoted command line.
# The wrapper runs once per connection and first re-resolves the live interop
# socket, so a relay started from a session that has since exited keeps
# working instead of inheriting a dead $WSL_INTEROP forever.
# omw_write_exec_wrapper <wrapper-path> <argv...>
omw_write_exec_wrapper() {
  local wrapper="$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    echo '# Generated by omarchy-wsl (interop.sh): per-connection relay launcher.'
    printf 'if [ -r %q ]; then . %q && omw_fix_interop >/dev/null 2>&1; fi\n' "$_OMW_LIB_PATH" "$_OMW_LIB_PATH"
    printf 'exec'
    printf ' %q' "$@"
    printf '\n'
  } >"${wrapper}.$$"
  chmod 0700 "${wrapper}.$$"
  mv -f "${wrapper}.$$" "$wrapper"
}
