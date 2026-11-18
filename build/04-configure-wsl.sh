#!/usr/bin/env bash
# Step 04: systemd units, locale and first-boot behaviour under WSL.
#
# WSL owns the kernel, networking, /etc/resolv.conf, the clock and the console,
# so the units that would fight it are masked; systemd-firstboot is masked
# because it waits for console input that never comes. No user is created
# here: the OOBE (/usr/lib/wsl/oobe.sh) provisions uid 1000 on first launch.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "masking units WSL replaces"
systemctl mask \
  systemd-firstboot.service \
  systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
  systemd-network-generator.service \
  systemd-resolved.service \
  systemd-timesyncd.service \
  tmp.mount
systemctl disable sshd.service getty@tty1.service 2>/dev/null || true
rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service
rm -rf /etc/systemd/network/*

log "enabling first-boot units"
systemctl enable omarchy-pacman-init.service
if is_installed docker; then
  systemctl enable docker.socket
fi
systemctl set-default multi-user.target

log "locale en_US.UTF-8"
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' >/etc/locale.conf

# /etc/os-release came from the omarchy-wsl package (etc-overrides) and from
# make install-rootfs; the filesystem package's /usr/lib/os-release stays Arch.
grep -q '^VARIANT_ID=wsl$' /etc/os-release || die "/etc/os-release is not the Omarchy WSL one"
[[ ! -L /etc/os-release ]] || die "/etc/os-release is still a symlink"
log "$(. /etc/os-release && echo "$PRETTY_NAME")"
