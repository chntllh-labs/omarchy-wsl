#!/usr/bin/env bash
# Step 01: turn the verified stock rootfs (Arch Linux ARM or the Arch Linux
# bootstrap) into an up-to-date, lean base that pacman can serve from the
# pinned repositories.
#
#   - /etc/pacman.conf and the mirrorlist come from wsl/pacman (upstream
#     Omarchy's stable templates: [omarchy] first, HTTPS mirrors, NoExtract
#     under [options], no ALARM [aur]).
#   - The container cannot run pacman's Landlock sandbox or download user and
#     overlayfs confuses CheckSpace: those are relaxed for the build only;
#     build/99-cleanup.sh reinstalls the shipped pacman.conf.
#   - The keyring is initialised and the pinned Omarchy key trusted BEFORE the
#     first sync/upgrade.
#   - Arch Linux ARM's board packages, /boot and the `alarm` user (uid 1000)
#     go; root's password hash is replaced by a lock.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARCH=$(pacman_arch)
KEYRING=$(distro_keyring)
SRC="$OMARCHY_BUILD_ROOT"

log "pacman configuration for $ARCH"
install -m 0644 "$SRC/wsl/pacman/pacman.conf.$ARCH" /etc/pacman.conf
install -m 0644 "$SRC/wsl/pacman/mirrorlist.$ARCH" /etc/pacman.d/mirrorlist
if [[ -n ${PACMAN_MIRROR:-} ]]; then
  log "mirror override: $PACMAN_MIRROR"
  printf 'Server = %s\n' "$PACMAN_MIRROR" >/etc/pacman.d/mirrorlist
fi
pacman_conf_set DisableSandbox
pacman_conf_unset DownloadUser
pacman_conf_unset CheckSpace
pacman_conf_set ParallelDownloads 10

log "initialising the pacman keyring ($KEYRING)"
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate "$KEYRING"
import_pinned_key "$SRC/$(lock OMARCHY_KEY_FILE)" "$(lock OMARCHY_KEY_FPR)"

log "refreshing the distribution keyring"
pacman -Sy --noconfirm --needed "$KEYRING-keyring"

if [[ $ARCH == aarch64 ]]; then
  # WSL supplies the kernel, firmware and networking; none of these run there.
  board_pkgs=()
  for pkg in linux-aarch64 linux-firmware linux-firmware-whence mkinitcpio mkinitcpio-busybox netctl dhcpcd uboot-tools; do
    is_installed "$pkg" && board_pkgs+=("$pkg")
  done
  if ((${#board_pkgs[@]} > 0)); then
    log "removing board packages: ${board_pkgs[*]}"
    pacman -Rns --noconfirm "${board_pkgs[@]}"
  fi
fi
find /boot /usr/lib/modules /usr/lib/firmware -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

if id -u alarm >/dev/null 2>&1; then
  log "removing the stock 'alarm' user (frees uid 1000 for the OOBE)"
  userdel --remove alarm 2>/dev/null || userdel alarm
fi
getent group alarm >/dev/null && groupdel alarm

log "locking root (no password hash ships)"
usermod -p '!*' root
[[ $(awk -F: '$1 == "root" { print $2 }' /etc/shadow) == '!*' ]] || die "root is not locked"

log "upgrading the base system"
pacman -Syu --noconfirm

log "installing the core package set"
mapfile -t core < <(read_packages "$SRC/packages/omarchy-wsl-base.packages")
pacman_install "${core[@]}"

log "bootstrap complete: $(pacman -Q pacman), $(pacman -Q | wc -l) packages"
