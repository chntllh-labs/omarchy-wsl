#!/bin/bash
# ==============================================================================
# Omarchy WSL: root filesystem sanitiser (last step of the image build)
# ==============================================================================
# Removes build users, credentials, per-machine identity, caches and logs, and
# documentation that predates the NoExtract rules. Everything else is left
# exactly as pacman installed it:
#   - static archives are NOT removed: libc.so links libc_nonshared.a and gcc
#     needs libgcc.a / libssp_nonshared.a, so `gcc` and makepkg keep working;
#   - /usr/share/doc/omarchy-wsl ships (the docs the image refers to);
#   - fonts, man pages and Python bytecode are untouched (pacman owns them).
# Timestamps are normalised later, when the export is archived.
#
# Safe to re-run. ROOT=/path sanitises a mounted tree instead of / (tests).
# ==============================================================================

set -euo pipefail

ROOT="${ROOT:-}"
ROOT="${ROOT%/}"
r() { printf '%s%s' "$ROOT" "$1"; }
log() { echo "==> [sanitizer] $*"; }
# clear_dir <path>: empty a directory, keeping the directory itself.
clear_dir() {
  local d
  d=$(r "$1")
  [[ -n $1 && $1 != / && -d $d ]] || return 0
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

# find over the root filesystem only (never /proc, /sys, /dev or bind mounts).
find_root() {
  find "$(r /)" -xdev \( -path "$(r /proc)" -o -path "$(r /sys)" -o -path "$(r /dev)" -o -path "$(r /run)" \) -prune -o "$@"
}

log "removing build users and their sudo rules"
for user in omarchy-builder builder makepkg aur; do
  if [[ -z $ROOT ]] && id "$user" >/dev/null 2>&1; then
    userdel --remove "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
  fi
  rm -f "$(r /etc/sudoers.d/)"{90-,}"$user" 2>/dev/null || true
done
rm -rf "$(r /var/lib/omarchy-builder)" "$(r /home/builder)" "$(r /home/makepkg)" "$(r /home/aur)"

log "removing credentials and interactive state from /root and /home"
for home in "$(r /root)" "$(r /home)"; do
  [[ -d $home ]] || continue
  find "$home" -xdev \( \
    -path '*/.ssh' -o -path '*/.gnupg' -o -path '*/.aws' -o -path '*/.azure' -o \
    -path '*/.kube' -o -path '*/.docker' -o -path '*/.claude' -o -path '*/.config/gh' -o \
    -path '*/.config/gcloud' -o -path '*/.config/hub' -o -path '*/.config/op' -o \
    -path '*/.local/share/keyrings' -o -path '*/.password-store' -o -path '*/.cache' -o \
    -path '*/.npm' -o -path '*/.cargo/registry' -o -path '*/go/pkg' \
    \) -prune -exec rm -rf {} + 2>/dev/null || true
  find "$home" -xdev -type f \( \
    -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' -o -name '.git-credentials' -o \
    -name '.gitconfig' -o -name '.claude.json' -o -name 'credentials' -o -name 'credentials.toml' -o \
    -name '.vault-token' -o -name '*.pem' -o -name '*.key' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o \
    -name 'id_ecdsa*' \) -delete 2>/dev/null || true
done

log "removing shell history and editor state"
find_root -type f \( -name '.*_history' -o -name '.lesshst' -o -name '.viminfo' -o \
  -name '.wget-hsts' -o -name '*.swp' -o -name '*.swo' \) -print0 2>/dev/null |
  xargs -0 rm -f 2>/dev/null || true
find_root -type d -path '*/nvim/shada' -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true

log "removing per-machine identity"
# /etc/machine-id must exist and be empty: systemd treats an empty file as
# "first boot" and generates the id; a missing file breaks some units.
: >"$(r /etc/machine-id)"
chmod 0444 "$(r /etc/machine-id)"
rm -f "$(r /var/lib/dbus/machine-id)"
ln -sf /etc/machine-id "$(r /var/lib/dbus/machine-id)" 2>/dev/null || true
rm -f "$(r /var/lib/systemd/random-seed)" "$(r /var/lib/urandom/random-seed)"
rm -f "$(r /etc/ssh/)"ssh_host_* 2>/dev/null || true
rm -f "$(r /etc/omarchy-user.conf)" "$(r /var/lib/omarchy/oobe_completed)"
# WSL generates these per instance. The container runtime keeps them bind
# mounted during RUN, so removal can fail here; the exporter removes them too.
rm -f "$(r /etc/resolv.conf)" "$(r /etc/hostname)" 2>/dev/null || true

log "removing the pacman keyring, caches, sync databases and locks"
gpgconf --homedir "$(r /etc/pacman.d/gnupg)" --kill all 2>/dev/null || true
rm -rf "$(r /etc/pacman.d/gnupg)"
clear_dir /var/cache/pacman/pkg
clear_dir /var/lib/pacman/sync
rm -f "$(r /var/lib/pacman/db.lck)"

log "truncating logs and clearing temporary directories"
find "$(r /var/log)" -xdev -type f -exec truncate -s 0 {} + 2>/dev/null || true
clear_dir /var/log/journal
find "$(r /tmp)" "$(r /var/tmp)" -xdev -mindepth 1 -delete 2>/dev/null || true
chmod 1777 "$(r /tmp)" "$(r /var/tmp)"

log "removing documentation and translations unpacked before NoExtract applied"
find "$(r /usr/share/doc)" -mindepth 1 -maxdepth 1 ! -name omarchy-wsl -exec rm -rf {} + 2>/dev/null || true
clear_dir /usr/share/gtk-doc
clear_dir /usr/share/help
clear_dir /usr/share/info
if [[ -d $(r /usr/share/locale) ]]; then
  find "$(r /usr/share/locale)" -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name locale.alias -exec rm -rf {} + 2>/dev/null || true
fi

log "done"
