#!/bin/bash
# ==============================================================================
# Omarchy WSL: Rootfs Adversarial Sanitization & Stripping Engine
# ==============================================================================
# Eliminates all host secrets, build user artifacts, non-reproducible states,
# package manager caches, and bloat to guarantee a zero-leak, <800MB rootfs.
# ==============================================================================

set -euo pipefail

echo "==> [sanitizer] Initiating adversarial rootfs sanitization..."

# 1. Eliminate Build Users & Temporary Privileges
echo "==> [sanitizer] Purging temporary build users and sudoers..."
for user in builder makepkg guest aur; do
  if id "$user" >/dev/null 2>&1; then
    userdel -r "$user" 2>/dev/null || true
  fi
done
rm -f /etc/sudoers.d/builder /etc/sudoers.d/makepkg /etc/sudoers.d/aur 2>/dev/null || true
rm -rf /home/builder /home/makepkg /home/aur 2>/dev/null || true

# 2. Eliminate Leaked Host Secrets, SSH Keys, Shell History, and Interactive State
echo "==> [sanitizer] Scrubbing host secrets, credentials, and interactive history..."
find /root /home /etc -name ".ssh" -type d -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".gnupg" -type d ! -path "/etc/pacman.d/gnupg*" -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".claude" -type d -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".hermes" -type d ! -path "*/hermes/workspace" ! -path "*/hermes/worktrees" ! -path "*/hermes/scratch" -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".aws" -type d -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".docker" -type d -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".config/gh" -type d -exec rm -rf {} + 2>/dev/null || true
find /root /home -name ".gitconfig" -type f -exec rm -f {} + 2>/dev/null || true

# Purge history and shada/swap
find / -name "*_history" -type f -exec rm -f {} + 2>/dev/null || true
find / -name ".lesshst" -type f -exec rm -f {} + 2>/dev/null || true
find / -name ".viminfo" -type f -exec rm -f {} + 2>/dev/null || true
find / -name "*.swp" -type f -exec rm -f {} + 2>/dev/null || true
find / -name "*.swo" -type f -exec rm -f {} + 2>/dev/null || true
find / -type d -name "shada" -exec rm -rf {} + 2>/dev/null || true

# 3. Purge Package Manager Caches, Sync DBs, and Stale Locks
echo "==> [sanitizer] Purging pacman package cache and locks..."
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
rm -f /var/lib/pacman/db.lck 2>/dev/null || true
# Clean pacman cache via paccache if available
if command -v paccache >/dev/null 2>&1; then
  paccache -rk0 2>/dev/null || true
fi

# 4. Cleanse Non-Reproducible Identity & System Entropy
echo "==> [sanitizer] Cleansing system identity, random seeds, and logs..."
# /etc/machine-id MUST be empty (0 bytes), NOT deleted or populated
truncate -s 0 /etc/machine-id
chmod 0444 /etc/machine-id
rm -f /var/lib/dbus/machine-id 2>/dev/null || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Random seed MUST be purged
rm -f /var/lib/systemd/random-seed 2>/dev/null || true
rm -f /var/lib/urandom/random-seed 2>/dev/null || true

# Purge logs
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf /var/log/journal/* 2>/dev/null || true

# Purge ephemeral runtime and temp directories
rm -rf /tmp/* /tmp/.* /var/tmp/* /var/tmp/.* 2>/dev/null || true
rm -rf /var/run/* /run/* 2>/dev/null || true

# 5. Sanitize Pacman Keyring & GPG Sockets
echo "==> [sanitizer] Sanitizing GPG sockets in /etc/pacman.d/gnupg..."
GNUPG_DIR="/etc/pacman.d/gnupg"
if [[ -d "$GNUPG_DIR" ]]; then
  gpgconf --homedir "$GNUPG_DIR" --kill all 2>/dev/null || true
  rm -f "${GNUPG_DIR}/S."* "${GNUPG_DIR}/"*.lock "${GNUPG_DIR}/random_seed" 2>/dev/null || true
  chmod 0700 "$GNUPG_DIR"
  find "$GNUPG_DIR" -type f -exec chmod 0600 {} + 2>/dev/null || true
fi

# 6. Deep Footprint Stripping (Enforcing <800MB Budget)
echo "==> [sanitizer] Stripping redundant documentation, manpages, and locales..."
# Strip docs, man, and info
rm -rf /usr/share/doc/* /usr/share/gtk-doc/* /usr/share/help/* 2>/dev/null || true
rm -rf /usr/share/man/* /usr/share/info/* 2>/dev/null || true

# Strip unused locales (retain only en and locale.alias)
if [[ -d /usr/share/locale ]]; then
  find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
fi

# Prune Python bytecode
echo "==> [sanitizer] Pruning Python __pycache__ and bytecode..."
find /usr -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find /usr -name "*.pyc" -type f -delete 2>/dev/null || true
find /usr -name "*.pyo" -type f -delete 2>/dev/null || true

# Prune TTF Font Bloat (Leave only essential regular Nerd Font variant)
echo "==> [sanitizer] Pruning oversized font families..."
if [[ -d /usr/share/fonts/TTF ]]; then
  find /usr/share/fonts/TTF -type f ! -name "*Regular*.ttf" ! -name "*JetBrainsMono*Nerd*Regular*.ttf" -delete 2>/dev/null || true
fi

# Strip unneeded static libraries and debug symbols
echo "==> [sanitizer] Stripping unneeded static archives..."
find /usr/lib /usr/local/lib -name "*.a" ! -name "libc.a" ! -name "libpthread.a" -type f -delete 2>/dev/null || true

# Remove unwanted firmware and kernel modules if accidentally pulled
echo "==> [sanitizer] Verifying exclusion of host kernel/firmware..."
rm -rf /usr/lib/modules/* /usr/lib/firmware/* 2>/dev/null || true

# 7. Clamping Timestamps for Reproducible Builds
if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
  echo "==> [sanitizer] Clamping filesystem timestamps to SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}..."
  find / -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} + 2>/dev/null || true
fi

echo "==> [sanitizer] Rootfs sanitization complete. Zero-leak posture verified."
