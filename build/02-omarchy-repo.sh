#!/usr/bin/env bash
# Step 02: Omarchy's signed repository and the CLI tool set.
#
# [omarchy] (https://pkgs.omarchy.org/stable/$arch) publishes omarchy-keyring,
# omarchy-nvim, yay and mise-bin prebuilt for both aarch64 and x86_64, so
# nothing is compiled from the AUR. The pinned key was trusted in step 01;
# installing omarchy-keyring hands trust over to pacman's own keyring package.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$OMARCHY_BUILD_ROOT"
ARCH=$(pacman_arch)
KEY_FPR=$(lock OMARCHY_KEY_FPR)

grep -q '^\[omarchy\]' /etc/pacman.conf || die "[omarchy] missing from /etc/pacman.conf"
pacman -Sy --noconfirm

mapfile -t omarchy_pkgs < <(read_packages "$SRC/packages/omarchy-wsl-omarchy.packages")
for pkg in "${omarchy_pkgs[@]}"; do
  repo=$(pacman -Sp --print-format '%r' "$pkg" 2>/dev/null | tail -n 1)
  [[ $repo == omarchy ]] || die "$pkg resolves to repository '${repo:-none}', expected [omarchy]"
done

log "installing the Omarchy keyring"
pacman_install omarchy-keyring
keyring=/usr/share/pacman/keyrings/omarchy.gpg
gpg --homedir "$(mktemp -d)" --batch --show-keys --with-colons "$keyring" | grep -q "^fpr:::::::::${KEY_FPR}:" ||
  die "omarchy-keyring does not carry the pinned key $KEY_FPR"
if [[ $(sha256sum "$keyring" | cut -d' ' -f1) != "$(lock OMARCHY_KEYRING_GPG_SHA256)" ]]; then
  warn "omarchy-keyring content changed since upstream.lock was written (signed by the pinned key; review and bump the lock)"
fi
pacman-key --list-keys "$KEY_FPR" >/dev/null || die "pinned Omarchy key is not in the pacman keyring"

log "installing from [omarchy]: ${omarchy_pkgs[*]}"
pacman_install "${omarchy_pkgs[@]}"

log "installing the CLI tool set"
mapfile -t tools < <(read_packages "$SRC/packages/omarchy-wsl-tools.packages")
pacman_install "${tools[@]}"

case "$ARCH" in
  aarch64) elf_machine="ARM aarch64" ;;
  x86_64) elf_machine="x86-64" ;;
esac
for bin in yay mise; do
  file -L "$(command -v "$bin")" | grep -q "$elf_machine" || die "$bin is not a native $ARCH binary"
  log "$bin $("$bin" --version 2>/dev/null | head -n 1) ($ARCH)"
done
