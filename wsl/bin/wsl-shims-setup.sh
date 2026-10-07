#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Windows Host Binary Interoperability Shims
# /usr/lib/omarchy-wsl/bin/wsl-shims-setup.sh
# ==============================================================================
# Creates high-performance symlinks to essential Windows tools in
# /usr/lib/omarchy-wsl/bin, providing seamless access to PowerShell, Explorer,
# clipboard, and Windows Terminal without appending the entire Windows %PATH%.
# ==============================================================================

set -euo pipefail

SHIMS_DIR="/usr/lib/omarchy-wsl/bin"
mkdir -p "$SHIMS_DIR"

link_tool() {
  local tool_name="$1"
  shift
  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      ln -sf "$candidate" "${SHIMS_DIR}/${tool_name}"
      return 0
    fi
  done
}

# 1. Windows PowerShell & PowerShell 7
link_tool "powershell.exe" \
  "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

link_tool "pwsh.exe" \
  "/mnt/c/Program Files/PowerShell/7/pwsh.exe" \
  "/mnt/c/Program Files/PowerShell/7-preview/pwsh.exe"

# 2. Command Prompt & Windows Explorer
link_tool "cmd.exe" \
  "/mnt/c/Windows/System32/cmd.exe"

link_tool "explorer.exe" \
  "/mnt/c/Windows/explorer.exe"

# 3. Windows Clipboard & WSL CLI
link_tool "clip.exe" \
  "/mnt/c/Windows/System32/clip.exe"

link_tool "wsl.exe" \
  "/mnt/c/Windows/System32/wsl.exe"

# 4. Windows Terminal
if [[ -d "/mnt/c/Users" ]]; then
  WT_CANDIDATE=$(find /mnt/c/Users -maxdepth 5 -type f -name "wt.exe" 2>/dev/null | head -n 1 || true)
  if [[ -n "$WT_CANDIDATE" ]]; then
    ln -sf "$WT_CANDIDATE" "${SHIMS_DIR}/wt.exe"
  fi
fi

# 5. Git Credential Manager (Windows)
link_tool "git-credential-manager.exe" \
  "/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe" \
  "/mnt/c/Program Files (x86)/Git/mingw64/bin/git-credential-manager.exe"

chmod -R 0755 "$SHIMS_DIR"
