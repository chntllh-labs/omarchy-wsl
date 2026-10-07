#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Shared Windows Interop Library
# /usr/lib/omarchy-wsl/interop.sh
# ==============================================================================
# Sourced (never executed) by the Windows integration tools:
#   omarchy-open, omarchy-clip, omarchy-notify, omarchy-sync-dirs,
#   omarchy-docker-bridge, omarchy-watch-bridge, omarchy-power-governor,
#   omarchy-ssh-agent-bridge, omarchy-git-credential-bridge
#
# Design rules (see docs/WINDOWS-INTEGRATION-QOL.md):
# 1. Never rely on the Windows %PATH% (wsl.conf sets appendWindowsPath=false).
#    Every Windows binary is resolved to an absolute DrvFs path.
# 2. Never interpolate user data into cmd.exe command lines. PowerShell is only
#    ever invoked via -EncodedCommand, and user data travels as base64 or stdin.
# 3. Every interop call is bounded by a timeout. A hung Windows process must
#    never hang a shell, a build, or a git credential request.
#
# Test seams (used by tests/test_windows_integration.sh):
#   OMW_FORCE_WSL=1        treat the current kernel as WSL
#   OMW_FORCE_INTEROP=1    treat binfmt WSLInterop as enabled
#   OMW_MOUNT_ROOT=<dir>   DrvFs automount root (default: parsed from wsl.conf)
#   OMW_WSL_CONF=<file>    alternate /etc/wsl.conf
#   OMW_MOUNTINFO=<file>   alternate /proc/self/mountinfo
#   OMW_POWERSHELL=<exe>   explicit powershell.exe
# ==============================================================================

# Guard against double-sourcing.
[[ -n "${_OMW_INTEROP_LOADED:-}" ]] && return 0
_OMW_INTEROP_LOADED=1

OMW_TAG="${OMW_TAG:-omarchy}"
OMW_TIMEOUT="${OMW_TIMEOUT:-15}"

omw_log()  { [[ -n "${OMW_QUIET:-}" ]] || echo -e "\e[32m[${OMW_TAG}]\e[0m $*" >&2; }
omw_warn() { echo -e "\e[33m[${OMW_TAG}:WARN]\e[0m $*" >&2; }
omw_err()  { echo -e "\e[31m[${OMW_TAG}:ERROR]\e[0m $*" >&2; }
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
# idle pipe can block forever.
omw_ps_run() {
  local stdin=0
  if [[ "${1:-}" == "--stdin" ]]; then
    stdin=1
    shift
  fi
  local script="$1" ps encoded
  ps=$(omw_powershell) || { omw_err "powershell.exe not found under $(omw_mount_root)"; return 127; }
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
omw_win_env() {
  local var="$1" cached cmd value
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  if cached=$(omw_cache_get "winenv-${var}" 86400); then
    echo "$cached"
    return 0
  fi
  cmd=$(omw_find_exe cmd.exe) || return 127
  value=$(
    cd "$(omw_system_root)" 2>/dev/null || exit 1
    timeout 5 "$cmd" /d /c "echo %${var}%" 2>/dev/null | tr -d '\r'
  ) || true
  # cmd echoes the literal token when the variable is undefined.
  if [[ -z "$value" || "$value" == "%${var}%" ]]; then
    return 1
  fi
  omw_cache_put "winenv-${var}" "$value"
  echo "$value"
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
  echo "\\\\wsl.localhost\\$(omw_distro_name)${abs//\//\\}"
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
omw_runtime_dir() {
  local base="${XDG_RUNTIME_DIR:-}"
  if [[ -z "$base" || ! -d "$base" || ! -w "$base" ]]; then
    base="/tmp/omarchy-runtime-$(id -u)"
  fi
  local dir="$base/omarchy"
  if [[ ! -d "$dir" ]]; then
    (umask 077 && mkdir -p "$dir")
  fi
  # Refuse a runtime dir another user could have planted.
  if [[ "$(stat -c %u "$dir")" != "$(id -u)" ]]; then
    omw_err "Runtime dir $dir is not owned by $(id -un); refusing to use it."
    return 1
  fi
  chmod 0700 "$dir" 2>/dev/null || true
  echo "$dir"
}

# omw_cache_get <key> <ttl-seconds>
omw_cache_get() {
  local file now mtime
  file="$(omw_runtime_dir 2>/dev/null)/cache-${1//[^A-Za-z0-9_.-]/_}" || return 1
  [[ -f "$file" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  (( now - mtime <= $2 )) || return 1
  cat "$file"
}

# omw_cache_put <key> <value>
omw_cache_put() {
  local dir file
  dir=$(omw_runtime_dir 2>/dev/null) || return 0
  file="$dir/cache-${1//[^A-Za-z0-9_.-]/_}"
  printf '%s\n' "$2" >"${file}.$$" && mv -f "${file}.$$" "$file"
}

# omw_require_interop — exit with a precise diagnosis when interop is missing.
omw_require_interop() {
  omw_is_wsl || omw_die "Not running under WSL; Windows interop is unavailable."
  omw_interop_enabled || omw_die "WSL interop is disabled (binfmt WSLInterop missing). See /etc/binfmt.d/WSLInterop.conf and [interop] in /etc/wsl.conf."
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
# omw_write_exec_wrapper <wrapper-path> <argv...>
omw_write_exec_wrapper() {
  local wrapper="$1"
  shift
  {
    echo '#!/bin/sh'
    printf 'exec'
    printf ' %q' "$@"
    printf '\n'
  } >"${wrapper}.$$"
  chmod 0700 "${wrapper}.$$"
  mv -f "${wrapper}.$$" "$wrapper"
}
