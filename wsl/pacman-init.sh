#!/bin/bash
# ==============================================================================
# Omarchy WSL: Deterministic, Offline-Safe Pacman Keyring Initialization
# ==============================================================================
# Guarantees local keyring initialization without internet dependency,
# preventing gpg-agent hanging, socket conflicts, and clock-skew failures.
# ==============================================================================

set -euo pipefail

GNUPG_DIR="/etc/pacman.d/gnupg"

# Fast-path: if trustdb exists and is non-empty, keyring is already initialized
if [[ -s "${GNUPG_DIR}/trustdb.gpg" ]]; then
  # Ensure no stale socket files from prior crashes
  rm -f "${GNUPG_DIR}/S."* "${GNUPG_DIR}/"*.lock 2>/dev/null || true
  exit 0
fi

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) distro_keyring="archlinuxarm" ;;
  x86_64)  distro_keyring="archlinux" ;;
  *)
    echo "[omarchy-pacman-init] ERROR: Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

keyrings=("$distro_keyring")
[[ -f "/usr/share/pacman/keyrings/omarchy.gpg" ]] && keyrings+=("omarchy")

echo "[omarchy-pacman-init] Initializing pacman keyring for $ARCH..."

# Guard against clock skew on clean/offline boot
# If RTC is before 2024-01-01, GPG rejects keys as "created in the future"
CURRENT_TIME=$(date +%s)
MIN_EPOCH=1704067200 # 2024-01-01 00:00:00 UTC
if (( CURRENT_TIME < MIN_EPOCH )); then
  FALLBACK_EPOCH=${SOURCE_DATE_EPOCH:-1775000000}
  echo "[omarchy-pacman-init] WARNING: System clock is set to past ($CURRENT_TIME). Clamping to fallback ($FALLBACK_EPOCH)..."
  date -s "@${FALLBACK_EPOCH}" 2>/dev/null || true
fi

# Ensure clean directory and permissions
mkdir -p -m 0700 "$GNUPG_DIR"
rm -f "${GNUPG_DIR}/S."* "${GNUPG_DIR}/"*.lock 2>/dev/null || true

# Enforce offline-safe GPG config
cat << 'EOF' > "${GNUPG_DIR}/gpg.conf"
no-greeting
no-permission-warning
keyserver-options timeout=5
no-auto-key-retrieve
EOF
chmod 0600 "${GNUPG_DIR}/gpg.conf"

# Initialize local master key
pacman-key --init

# Populate trusted distribution keys offline from /usr/share/pacman/keyrings/
pacman-key --populate "${keyrings[@]}"

# Kill background GPG agents and purge ephemeral sockets
gpgconf --homedir "$GNUPG_DIR" --kill all 2>/dev/null || true
rm -f "${GNUPG_DIR}/S."* "${GNUPG_DIR}/"*.lock 2>/dev/null || true
chmod 0700 "$GNUPG_DIR"
find "$GNUPG_DIR" -type f -exec chmod 0600 {} + 2>/dev/null || true

echo "[omarchy-pacman-init] Pacman keyring successfully initialized and sanitized."
