#!/usr/bin/env bash
# Step 03: the omarchy-wsl package and the rest of the root filesystem.
#
#   1. Fetch exactly the pinned upstream commit (depth 1, not the 1.2 GB
#      history); the PKGBUILD re-checks the tree against the same sha256
#      makepkg uses for git sources.
#   2. makepkg the omarchy-wsl package as an unprivileged builder: upstream's
#      CLI/themes/defaults + this repository's WSL layer (make install-pkg).
#   3. pacman -U it, so pacman owns every file.
#   4. make install-rootfs DESTDIR=/ adds the machine-level files other packages
#      own (/etc/os-release) and re-lays the package files byte-identically;
#      make verify-rootfs proves the root filesystem matches rootfs.manifest.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$OMARCHY_BUILD_ROOT"
COMMIT=$(lock OMARCHY_COMMIT)
SOURCE_SHA=$(lock OMARCHY_SOURCE_SHA256)
UPSTREAM_URL=$(lock OMARCHY_SOURCE_URL)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
export OMARCHY_WSL_GIT_SHA="${OMARCHY_WSL_GIT_SHA:-unknown}"

ensure_builder
work="$BUILDER_HOME/build"
upstream="$BUILDER_HOME/omarchy-src"
rm -rf "$work" "$upstream"
install -d -o "$BUILDER_USER" -g "$BUILDER_USER" "$work" "$upstream"

log "fetching upstream Omarchy $(lock OMARCHY_TAG) at ${COMMIT:0:12}"
as_builder git -C "$upstream" init -q
as_builder git -C "$upstream" fetch -q --depth 1 "$UPSTREAM_URL" "$COMMIT"
as_builder git -C "$upstream" -c advice.detachedHead=false checkout -q FETCH_HEAD
sum=$(as_builder git -C "$upstream" -c core.abbrev=no archive --format tar "$COMMIT" | sha256sum | cut -d' ' -f1)
[[ $sum == "$SOURCE_SHA" ]] || die "upstream tree sha256 $sum != upstream.lock $SOURCE_SHA"
log "upstream tree verified (sha256 $sum)"

cp -a "$SRC/packages/PKGBUILDs/omarchy-wsl" "$work/"
chown -R "$BUILDER_USER:$BUILDER_USER" "$work"

log "makepkg omarchy-wsl"
(cd "$work/omarchy-wsl" && as_builder env OMARCHY_SRC="$upstream" OMARCHY_WSL_SRC="$SRC" \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" OMARCHY_WSL_GIT_SHA="$OMARCHY_WSL_GIT_SHA" \
  makepkg --syncdeps --noconfirm --needed --cleanbuild --force)
mapfile -t pkgfiles < <(cd "$work/omarchy-wsl" && as_builder makepkg --packagelist | grep -v -- '-debug-')
((${#pkgfiles[@]} == 1)) || die "makepkg produced ${#pkgfiles[@]} packages"
pacman -U --noconfirm "${pkgfiles[0]}"
pkgver=$(pacman -Q omarchy-wsl | awk '{print $2}')

log "installing machine-level files (make install-rootfs DESTDIR=/)"
make -C "$SRC" --no-print-directory install-rootfs DESTDIR=/ \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" OMARCHY_WSL_GIT_SHA="$OMARCHY_WSL_GIT_SHA" OMARCHY_WSL_PKGVER="$pkgver"
make -C "$SRC" --no-print-directory verify-rootfs ROOT=/

# shellcheck source=/dev/null
source /usr/share/omarchy/default/bash/env-bootstrap
version=$(omarchy-version)
[[ $version == "$(lock OMARCHY_VERSION)" ]] || die "omarchy-version reports '$version', expected $(lock OMARCHY_VERSION)"
for cmd in omarchy omarchy-theme-set omarchy-theme-list omarchy-update omarchy-doctor omarchy-theme-bridge omarchy-wsl-update; do
  command -v "$cmd" >/dev/null || die "$cmd missing after install"
done
log "Omarchy $version installed: $(find /usr/bin -maxdepth 1 -name 'omarchy*' | wc -l) commands, $(pacman -Ql omarchy-wsl | wc -l) package files"
