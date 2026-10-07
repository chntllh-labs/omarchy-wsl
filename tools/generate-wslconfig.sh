#!/usr/bin/env bash
# ==============================================================================
# Omarchy-WSL Host .wslconfig Generator (POSIX/Bash)
# ==============================================================================
# Generates a hardened .wslconfig targeting Windows 11 mirrored mode with safe
# fallbacks. Can be executed inside WSL (via /mnt/c) or in test runners.
# ==============================================================================

set -euo pipefail

OUTPUT_PATH=""
FORCE_NAT=0
DRY_RUN=0

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -o, --output PATH    Destination path for .wslconfig (default: Windows %USERPROFILE%/.wslconfig)
  -n, --force-nat      Force legacy NAT mode instead of mirrored networking
  -d, --dry-run        Print configuration to stdout without writing
  -h, --help           Show this help message
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)    OUTPUT_PATH="$2"; shift 2 ;;
    -n|--force-nat) FORCE_NAT=1; shift ;;
    -d|--dry-run)   DRY_RUN=1; shift ;;
    -h|--help)      usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

# Detect host memory and cores if in WSL or local environment
CORES=$(nproc 2>/dev/null || echo "8")
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "16777216")
MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1024 / 1024 ))
WSL_MEM_GB=$(( MEM_TOTAL_GB * 3 / 4 ))
[[ $WSL_MEM_GB -lt 4 ]] && WSL_MEM_GB=4
WSL_SWAP_GB=$(( WSL_MEM_GB / 4 ))
[[ $WSL_SWAP_GB -lt 2 ]] && WSL_SWAP_GB=2
[[ $WSL_SWAP_GB -gt 16 ]] && WSL_SWAP_GB=16

NETWORKING_MODE="mirrored"
DNS_TUNNELING="true"
AUTO_PROXY="true"
HOST_LOOPBACK="true"
FIREWALL="true"

if [[ $FORCE_NAT -eq 1 ]]; then
  NETWORKING_MODE="NAT"
  DNS_TUNNELING="false"
  AUTO_PROXY="false"
  HOST_LOOPBACK="false"
  FIREWALL="false"
fi

CONFIG=$(cat << EOF
# ==============================================================================
# Omarchy-WSL Host Virtualization Configuration (.wslconfig)
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ==============================================================================
[wsl2]
memory=${WSL_MEM_GB}GB
processors=${CORES}
swap=${WSL_SWAP_GB}GB
autoMemoryReclaim=gradual
pageReporting=true
nestedVirtualization=true

# Networking Mode Configuration
networkingMode=${NETWORKING_MODE}
dnsTunneling=${DNS_TUNNELING}
autoProxy=${AUTO_PROXY}
hostAddressLoopback=${HOST_LOOPBACK}
firewall=${FIREWALL}
ignoredPorts=5353,5355

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
EOF
)

if [[ $DRY_RUN -eq 1 ]]; then
  echo "$CONFIG"
  exit 0
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  # Try to detect Windows user profile under /mnt/c/Users
  if [[ -d "/mnt/c/Users" ]]; then
    # Find first non-system user folder
    WIN_USER=$(find /mnt/c/Users -maxdepth 1 -mindepth 1 -type d ! -name "Public" ! -name "Default" ! -name "Default User" ! -name "All Users" | head -n 1)
    if [[ -n "$WIN_USER" && -d "$WIN_USER" ]]; then
      OUTPUT_PATH="${WIN_USER}/.wslconfig"
    fi
  fi
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$HOME/.wslconfig"
fi

if [[ -f "$OUTPUT_PATH" ]]; then
  cp "$OUTPUT_PATH" "${OUTPUT_PATH}.bak.$(date +%s)"
fi

echo "$CONFIG" > "$OUTPUT_PATH"
echo "[omarchy-wsl] Successfully wrote hardened .wslconfig to: $OUTPUT_PATH"
