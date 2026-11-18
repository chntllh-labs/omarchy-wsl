#!/usr/bin/env bash
# Step 99: undo build-only settings, drop build leftovers, then sanitise.
# Files the container runtime bind-mounts during RUN (/etc/resolv.conf,
# /etc/hostname, /etc/hosts) are removed when the export is normalised
# (scripts/build-reproducible-rootfs.sh), outside the container build.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$OMARCHY_BUILD_ROOT"
ARCH=$(pacman_arch)

log "removing the package builder"
rm -f "/etc/sudoers.d/90-$BUILDER_USER"
if id -u "$BUILDER_USER" >/dev/null 2>&1; then
  userdel --remove "$BUILDER_USER" 2>/dev/null || userdel "$BUILDER_USER"
fi
rm -rf "$BUILDER_HOME"

log "dropping orphans and caches"
mapfile -t orphans < <(pacman -Qdtq || true)
((${#orphans[@]} == 0)) || pacman -Rns --noconfirm "${orphans[@]}"
pacman -Scc --noconfirm >/dev/null

log "shipping pacman.conf (sandbox, DownloadUser and CheckSpace back on)"
install -m 0644 "$SRC/wsl/pacman/pacman.conf.$ARCH" /etc/pacman.conf
install -m 0644 "$SRC/wsl/pacman/mirrorlist.$ARCH" /etc/pacman.d/mirrorlist
awk '/^\[/{s=$0} /^NoExtract/ && s != "[options]" {bad=1} END{exit bad}' /etc/pacman.conf ||
  die "NoExtract outside [options] in /etc/pacman.conf"
grep -q '^DisableSandbox' /etc/pacman.conf && die "DisableSandbox left in the shipped pacman.conf"

log "removing the build keyring (each install creates its own on first boot)"
gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
rm -rf /etc/pacman.d/gnupg

log "sanitising the root filesystem"
bash "$SRC/scripts/strip-rootfs.sh"

log "image ready: $(pacman -Q | wc -l) packages, $(du -sxh / 2>/dev/null | cut -f1)"
