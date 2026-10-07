# shellcheck shell=bash
# ==============================================================================
# Omarchy WSL: DrvFs Performance Boundary Guard
# /usr/lib/omarchy-wsl/drvfs-guard.sh  (sourced by /etc/profile.d/40-omarchy-drvfs-guard.sh)
# ==============================================================================
# Stops build tools from running inside Windows drives (/mnt/<drive>/... or a
# ~/win/* symlink into one). On DrvFs every stat() is a 9P round-trip to the
# Windows host and Windows-side edits never reach inotify, so builds crawl and
# dev servers stop hot-reloading.
#
#   OMARCHY_DRVFS_GUARD=block  (default) builds refuse to start, git warns
#   OMARCHY_DRVFS_GUARD=warn   everything warns, nothing is blocked
#   OMARCHY_DRVFS_GUARD=off    guard disabled
#
# Bypass once:  OMARCHY_DRVFS_GUARD=off cargo build     or   command cargo build
# ==============================================================================

[ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac
[ -n "${_OMARCHY_DRVFS_GUARD_LOADED:-}" ] && return 0
_OMARCHY_DRVFS_GUARD_LOADED=1

_omarchy_drvfs_mount_root() {
  local root
  root=$(sed -n '/^\[automount\]/,/^\[/{s/^[[:space:]]*root[[:space:]]*=[[:space:]]*//p}' /etc/wsl.conf 2>/dev/null | tr -d '"[:space:]')
  root="${root:-/mnt/}"
  printf '%s' "${root%/}"
}
_OMARCHY_DRVFS_ROOT="${OMARCHY_DRVFS_ROOT:-$(_omarchy_drvfs_mount_root)}"

# Returns 0 if the *physical* cwd is on a Windows drive. The logical $PWD is a
# free fast path; otherwise one `pwd -P` (~1 ms) catches symlinks such as
# ~/win/Downloads or ~/work -> /mnt/c/work.
_omarchy_on_drvfs() {
  local p
  case "$PWD/" in
    "$_OMARCHY_DRVFS_ROOT"/?/*) return 0 ;;
  esac
  p=$(pwd -P 2>/dev/null) || return 1
  case "$p/" in "$_OMARCHY_DRVFS_ROOT"/?/*) return 0 ;; esac
  return 1
}

# _omarchy_drvfs_gate <tool> <severity: build|vcs>
_omarchy_drvfs_gate() {
  local mode="${OMARCHY_DRVFS_GUARD:-block}"
  [ "$mode" = "off" ] && return 0
  _omarchy_on_drvfs || return 0
  if [ "$mode" = "block" ] && [ "$2" = "build" ]; then
    printf '\033[31m[omarchy]\033[0m refusing to run %s on a Windows drive (%s).\n' "$1" "$PWD" >&2
    printf '          DrvFs is slow for builds and file watchers miss Windows edits.\n' >&2
    printf '          Move the project to ~/src, or bypass: OMARCHY_DRVFS_GUARD=off %s ...\n' "$1" >&2
    return 1
  fi
  printf '\033[33m[omarchy]\033[0m %s on a Windows drive is slow; prefer ~/src (ext4).\n' "$1" >&2
  return 0
}

# `declare -F` declares a *float* in zsh, so test function existence per shell.
_omarchy_is_function() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    (( ${+functions[$1]} ))
  else
    declare -F "$1" >/dev/null 2>&1
  fi
}

_omarchy_drvfs_wrap() {
  local tool="$1" severity="$2"
  # Never shadow a user's own alias or function.
  if alias "$tool" >/dev/null 2>&1 || _omarchy_is_function "$tool"; then
    return 0
  fi
  eval "${tool}() { _omarchy_drvfs_gate ${tool} ${severity} || return 1; command ${tool} \"\$@\"; }"
}

for _omarchy_t in cargo make cmake ninja meson npm npx pnpm yarn bun deno go gradle mvn dotnet omarchy-build; do
  _omarchy_drvfs_wrap "$_omarchy_t" build
done
_omarchy_drvfs_wrap git vcs
unset _omarchy_t
