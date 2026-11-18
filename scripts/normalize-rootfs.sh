#!/usr/bin/env bash
# ==============================================================================
# normalize-rootfs.sh: export tar -> audited, deterministic .wsl (gzip tar)
# ==============================================================================
# Runs as root INSIDE a Linux container (scripts/build-reproducible-rootfs.sh
# starts it). Never run it on macOS: bsdtar drops setuid/sticky bits, system
# uids and security.capability xattrs.
#
#   normalize-rootfs.sh <export.tar> <output.wsl>
#
# Environment:
#   SOURCE_DATE_EPOCH     every mtime in the archive (required)
#   SEED_LEAK=1           plant known leaks before the audit (self-test: the
#                         run must fail and produce no output)
#   AUDIT_EXTRA_PATTERNS  passed through to tests/audit-rootfs-leaks.sh
#   HOST_UID/HOST_GID     owner of the output file on the host
#   AUDIT_SCRIPT          default /tests/audit-rootfs-leaks.sh
# ==============================================================================

set -euo pipefail

EXPORT="${1:?usage: normalize-rootfs.sh <export.tar> <output.wsl>}"
OUTPUT="${2:?usage: normalize-rootfs.sh <export.tar> <output.wsl>}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"
AUDIT_SCRIPT="${AUDIT_SCRIPT:-/tests/audit-rootfs-leaks.sh}"
ROOTFS=/rootfs

log() { echo "[normalize] $*"; }
((EUID == 0)) || {
  echo "[normalize] must run as root (inside a container)" >&2
  exit 1
}
[[ $(uname -s) == Linux ]] || {
  echo "[normalize] Linux only" >&2
  exit 1
}

log "extracting $(basename "$EXPORT") with ownership, modes and file capabilities"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xpf "$EXPORT" -C "$ROOTFS" --numeric-owner --xattrs --xattrs-include='security.capability' \
  --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' --exclude='run/*'

log "finalising per-instance files"
# The container runtime's own files: WSL generates hostname/resolv.conf per
# instance and /etc/hosts on every start.
rm -f "$ROOTFS/.dockerenv" "$ROOTFS/.containerenv" "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/hostname"
if [[ ! -s $ROOTFS/etc/hosts ]]; then
  printf '# Static table lookup for hostnames.\n# See hosts(5) for details.\n' >"$ROOTFS/etc/hosts"
  chmod 0644 "$ROOTFS/etc/hosts"
fi
: >"$ROOTFS/etc/machine-id"
chmod 0444 "$ROOTFS/etc/machine-id"
for d in dev proc sys run; do
  mkdir -p "$ROOTFS/$d"
  chmod 0755 "$ROOTFS/$d"
done
chmod 0555 "$ROOTFS/proc" "$ROOTFS/sys"
find "$ROOTFS/tmp" "$ROOTFS/var/tmp" -mindepth 1 -delete 2>/dev/null || true
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

if [[ ${SEED_LEAK:-0} == 1 ]]; then
  log "SEEDING KNOWN LEAKS (self-test: this run must fail)"
  install -d -m 0700 "$ROOTFS/root/.ssh" "$ROOTFS/home/leaktest/.config/gh"
  # Fake material, assembled at run time so the repository never contains a
  # literal key header or token.
  printf -- '-----BEGIN %s-----\nc2VlZGVkLWxlYWstdGVzdA==\n-----END %s-----\n' "OPENSSH PRIVATE KEY" "OPENSSH PRIVATE KEY" >"$ROOTFS/root/.ssh/id_ed25519"
  printf 'github.com:\n  oauth_token: gho_%s\n' "000000000000000000000000000000000000" >"$ROOTFS/home/leaktest/.config/gh/hosts.yml"
  printf 'machine example.invalid login seeded password leak\n' >"$ROOTFS/root/.netrc"
fi

log "auditing the tree that will be archived"
if ! AUDIT_EXTRA_PATTERNS="${AUDIT_EXTRA_PATTERNS:-}" bash "$AUDIT_SCRIPT" "$ROOTFS"; then
  echo "[normalize] AUDIT FAILED: refusing to write $OUTPUT" >&2
  rm -f "$OUTPUT" "$OUTPUT.tmp"
  exit 3
fi

log "packing deterministically (GNU tar POSIX, sorted, mtime @$SOURCE_DATE_EPOCH, gzip -n -9)"
tar --version | head -n 1
cd "$ROOTFS"
# shellcheck disable=SC2046  # one argument per top-level entry, C-sorted
LC_ALL=C tar --format=posix \
  --pax-option=delete=atime,delete=ctime,exthdr.name=%d/PaxHeaders/%f \
  --xattrs --xattrs-include=security.capability \
  --numeric-owner --sort=name --mtime="@${SOURCE_DATE_EPOCH}" \
  -cf - -C "$ROOTFS" $(LC_ALL=C ls -A "$ROOTFS") | gzip -n -9 >"$OUTPUT.tmp"
mv -f "$OUTPUT.tmp" "$OUTPUT"
if [[ -n ${HOST_UID:-} ]]; then
  chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUTPUT"
fi
log "wrote $OUTPUT ($(stat -c %s "$OUTPUT") bytes, sha256 $(sha256sum "$OUTPUT" | cut -d' ' -f1))"
