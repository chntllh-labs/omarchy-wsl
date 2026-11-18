#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Windows Host Binary Interoperability Shims
# /usr/lib/omarchy-wsl/bin/wsl-shims-setup.sh
# ==============================================================================
# Symlinks a curated set of Windows tools (PowerShell, cmd, Explorer, clip,
# wsl, Windows Terminal, Git Credential Manager) into /usr/lib/omarchy-wsl/bin,
# so they are reachable without appending the whole Windows %PATH%
# (wsl.conf: appendWindowsPath=false).
#
# Run as root at runtime (first boot or later): the Windows Terminal alias
# lives in the profile of the Windows user who launched WSL, which an image
# build cannot know.
#
# Safety:
#   * Paths come from the DrvFs mount root in wsl.conf and from the Windows
#     environment of the interop session (%LOCALAPPDATA%), never from a
#     recursive search of C:\Users: C:\Users\Public is writable by every
#     Windows user, so a binary found there must never land on PATH.
#   * wt.exe is an App Execution Alias (an NTFS reparse point). It is tested
#     with -e: it is not a regular file on DrvFs.
#
# Options: --dry-run (print the links, change nothing), -h/--help.
# Test seams: OMARCHY_SHIMS_DIR (default /usr/lib/omarchy-wsl/bin) plus the
# interop library seams (OMW_MOUNT_ROOT, OMW_FORCE_WSL, ...).
# ==============================================================================

set -euo pipefail

_self="$(readlink -f "${BASH_SOURCE[0]}")"
for _lib in "${OMARCHY_WSL_LIB:-}" "${_self%/*}/../lib/omarchy-wsl-interop.sh" "${_self%/*}/../../lib/omarchy-wsl-interop.sh" /usr/lib/omarchy-wsl/interop.sh; do
  # shellcheck source=SCRIPTDIR/../../lib/omarchy-wsl-interop.sh
  [[ -n "$_lib" && -r "$_lib" ]] && { source "$_lib"; break; }
done
declare -F omw_mount_root >/dev/null || { echo "wsl-shims-setup.sh: interop library not found" >&2; exit 1; }
OMW_TAG="wsl-shims-setup"

SHIMS_DIR="${OMARCHY_SHIMS_DIR:-/usr/lib/omarchy-wsl/bin}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,26p' "$_self" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) omw_err "Unknown option: $1"; exit 2 ;;
  esac
done

ROOT=$(omw_mount_root)
SYSROOT=$(omw_system_root 2>/dev/null || echo "$ROOT/c/Windows")
LINKED=0

# link_tool <name> <test: -x|-e> <candidates...>: link the first candidate.
link_tool() {
  local name="$1" test_op="$2" candidate
  shift 2
  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    case "$candidate" in
      "$ROOT"/?/Users/Public/*|"$ROOT"/?/Users/Default/*|"$ROOT"/?/Users/All\ Users/*) continue ;;
    esac
    if test "$test_op" "$candidate"; then
      if (( DRY_RUN )); then
        printf 'link %s -> %s\n' "${SHIMS_DIR}/${name}" "$candidate"
      else
        ln -sfn -- "$candidate" "${SHIMS_DIR}/${name}"
      fi
      LINKED=$((LINKED + 1))
      return 0
    fi
  done
  return 1
}

(( DRY_RUN )) || mkdir -p "$SHIMS_DIR"

# Windows user profile directories of the interop session (may be absent when
# interop is down; the profile-dependent links are then skipped, not guessed).
LOCALAPPDATA_UNIX=""
if lad=$(omw_win_env LOCALAPPDATA 2>/dev/null) && [[ -n "$lad" ]]; then
  LOCALAPPDATA_UNIX=$(omw_win_to_unix "$lad" 2>/dev/null || true)
fi

# 1. Windows PowerShell & PowerShell 7
link_tool powershell.exe -x "$SYSROOT/System32/WindowsPowerShell/v1.0/powershell.exe" || true
link_tool pwsh.exe -x \
  "$ROOT/c/Program Files/PowerShell/7/pwsh.exe" \
  "$ROOT/c/Program Files/PowerShell/7-preview/pwsh.exe" || true

# 2. Command Prompt, Explorer, clipboard, WSL CLI
link_tool cmd.exe -x "$SYSROOT/System32/cmd.exe" || true
link_tool explorer.exe -x "$SYSROOT/explorer.exe" || true
link_tool clip.exe -x "$SYSROOT/System32/clip.exe" || true
link_tool wsl.exe -x "$SYSROOT/System32/wsl.exe" || true

# 3. Windows Terminal: the App Execution Alias of the interop session's user
#    (%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe). Without interop, accept a
#    single unambiguous per-user alias; several users -> do not guess.
WT=""
if [[ -n "$LOCALAPPDATA_UNIX" && -e "$LOCALAPPDATA_UNIX/Microsoft/WindowsApps/wt.exe" ]]; then
  WT="$LOCALAPPDATA_UNIX/Microsoft/WindowsApps/wt.exe"
elif [[ -d "$ROOT/c/Users" ]]; then
  # Users/<u>/AppData/Local/Microsoft/WindowsApps/wt.exe is at depth 6.
  mapfile -t _wt < <(find "$ROOT/c/Users" -mindepth 6 -maxdepth 7 -name wt.exe \
    -path '*/AppData/Local/Microsoft/WindowsApps/wt.exe' \
    -not -path "$ROOT/c/Users/Public/*" -not -path "$ROOT/c/Users/Default/*" \
    -not -path "$ROOT/c/Users/All Users/*" 2>/dev/null)
  if (( ${#_wt[@]} == 1 )); then
    WT="${_wt[0]}"
  elif (( ${#_wt[@]} > 1 )); then
    omw_warn "Several Windows profiles have wt.exe and interop is unavailable; not guessing (re-run with interop)."
  fi
fi
if [[ -n "$WT" ]]; then link_tool wt.exe -e "$WT" || true; fi

# 4. Git Credential Manager (same discovery order as omarchy-git-credential-bridge)
GCM_CANDIDATES=(
  "$ROOT/c/Program Files/Git/ucrt64/bin/git-credential-manager.exe"          # Git for Windows >= 2.56 (x64)
  "$ROOT/c/Program Files/Git/mingw64/bin/git-credential-manager.exe"         # Git for Windows <= 2.55 (x64)
  "$ROOT/c/Program Files/Git/clangarm64/bin/git-credential-manager.exe"      # Git for Windows ARM64
  "$ROOT/c/Program Files/Git Credential Manager/git-credential-manager.exe"  # standalone
  "$ROOT/c/Program Files (x86)/Git Credential Manager/git-credential-manager.exe"
)
[[ -n "$LOCALAPPDATA_UNIX" ]] && GCM_CANDIDATES+=("$LOCALAPPDATA_UNIX/Programs/Git Credential Manager/git-credential-manager.exe")
link_tool git-credential-manager.exe -x "${GCM_CANDIDATES[@]}" || true

(( DRY_RUN )) || chmod 0755 "$SHIMS_DIR"
omw_log "${LINKED} Windows shim(s) $( (( DRY_RUN )) && echo planned || echo linked ) in $SHIMS_DIR"
