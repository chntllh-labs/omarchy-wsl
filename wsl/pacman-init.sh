#!/bin/bash
# ==============================================================================
# /usr/lib/omarchy-wsl/pacman-init.sh
# Create this install's pacman keyring.
# ==============================================================================
# The image ships without /etc/pacman.d/gnupg so no two installs share a local
# master key. omarchy-pacman-init.service runs this on the first boot, and the
# OOBE calls it too (wsl --import without systemd, containers). A no-op once
# the keyring exists. Offline-safe: it only populates from the keyrings that
# archlinux(arm)-keyring and omarchy-keyring ship under /usr/share/pacman.
# ==============================================================================

set -euo pipefail

GNUPG_DIR="${OMARCHY_PACMAN_GNUPG:-/etc/pacman.d/gnupg}"
KEYRING_DIR="${OMARCHY_PACMAN_KEYRINGS:-/usr/share/pacman/keyrings}"

log() { printf '[omarchy-pacman-init] %s\n' "$*"; }

clear_stale_agent_files() {
  rm -f "$GNUPG_DIR"/S.* "$GNUPG_DIR"/*.lock "$GNUPG_DIR"/.#lk* 2>/dev/null || true
}

if [[ -s $GNUPG_DIR/trustdb.gpg ]]; then
  clear_stale_agent_files
  exit 0
fi

case "$(uname -m)" in
  aarch64) distro_keyring=archlinuxarm ;;
  x86_64) distro_keyring=archlinux ;;
  *)
    echo "[omarchy-pacman-init] unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

keyrings=()
for keyring in "$distro_keyring" omarchy; do
  [[ -f $KEYRING_DIR/$keyring.gpg ]] && keyrings+=("$keyring")
done
((${#keyrings[@]} > 0)) || {
  echo "[omarchy-pacman-init] no keyrings under $KEYRING_DIR" >&2
  exit 1
}

# GnuPG rejects keys "created in the future" when the clock is far behind (a
# VM restored from an old snapshot). Report it; never set the clock here.
if (($(date +%s) < 1704067200)); then
  log "WARNING: system clock reads $(date -u); key import may fail until it is corrected"
fi

log "initialising the pacman keyring (${keyrings[*]})"
install -d -m 0700 "$GNUPG_DIR"
clear_stale_agent_files
# Never reach for a keyserver from a boot service.
cat >"$GNUPG_DIR/gpg.conf" <<'CONF'
no-greeting
no-permission-warning
no-auto-key-retrieve
keyserver-options timeout=5
CONF
chmod 0600 "$GNUPG_DIR/gpg.conf"

pacman-key --gpgdir "$GNUPG_DIR" --init
pacman-key --gpgdir "$GNUPG_DIR" --populate "${keyrings[@]}"

gpgconf --homedir "$GNUPG_DIR" --kill all 2>/dev/null || true
clear_stale_agent_files
log "keyring ready"
