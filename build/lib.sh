# shellcheck shell=bash
# Shared helpers for the build/NN-*.sh image build steps. Sourced, never executed.
#
# Every step runs as root inside the image build (Containerfile). Inputs come
# from upstream.lock (parsed with a whitelist, never sourced) and from the
# environment the Containerfile sets.

set -euo pipefail

: "${OMARCHY_BUILD_ROOT:=/opt/omarchy-wsl-build}"
: "${MAKE_JOBS:=}"

BUILDER_USER=omarchy-builder
BUILDER_HOME=/var/lib/omarchy-builder

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _c_blue=$'\e[1;34m' _c_yellow=$'\e[1;33m' _c_red=$'\e[1;31m' _c_off=$'\e[0m'
else
  _c_blue='' _c_yellow='' _c_red='' _c_off=''
fi
log() { printf '%s==>%s %s\n' "$_c_blue" "$_c_off" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die() {
  printf '%s==> ERROR:%s %s\n' "$_c_red" "$_c_off" "$*" >&2
  exit 1
}

# lock <KEY>: value from upstream.lock (KEY=value lines only).
lock() {
  local key="$1" file="$OMARCHY_BUILD_ROOT/upstream.lock"
  awk -F= -v k="$key" '$0 ~ /^[A-Z0-9_]+=[^[:space:]]*$/ && $1 == k { print substr($0, length(k) + 2); found = 1 } END { exit found ? 0 : 1 }' "$file" ||
    die "upstream.lock has no $key"
}

# Machine name pacman and makepkg use: aarch64 or x86_64.
pacman_arch() { uname -m; }

distro_keyring() {
  case "$(pacman_arch)" in
    aarch64) echo archlinuxarm ;;
    x86_64) echo archlinux ;;
    *) die "Unsupported architecture: $(pacman_arch)" ;;
  esac
}

build_jobs() {
  if [[ -n $MAKE_JOBS ]]; then echo "$MAKE_JOBS"; else nproc; fi
}

# Print the package names in a .packages manifest (comments and blanks dropped).
read_packages() {
  local file="$1"
  [[ -f $file ]] || die "Package manifest not found: $file"
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$file"
}

pacman_install() {
  (($# > 0)) || return 0
  pacman -S --noconfirm --needed "$@"
}

is_installed() { pacman -Q "$1" >/dev/null 2>&1; }

# Set `Key = value` (or a bare `Key`) under [options] in pacman.conf, replacing
# any existing or commented-out occurrence. Never appends to the end of the
# file, which would land in the last repository section.
pacman_conf_set() {
  local key="$1" value="${2-}" conf="${3:-/etc/pacman.conf}" line
  if [[ -n $value ]]; then line="$key = $value"; else line="$key"; fi
  grep -q '^\[options\]' "$conf" || die "$conf has no [options] section"
  sed -i -E "/^#?[[:space:]]*${key}([[:space:]]*=.*)?[[:space:]]*$/d" "$conf"
  sed -i "/^\[options\]/a ${line}" "$conf"
}

pacman_conf_unset() {
  local key="$1" conf="${2:-/etc/pacman.conf}"
  sed -i -E "/^[[:space:]]*${key}([[:space:]]*=.*)?[[:space:]]*$/d" "$conf"
}

# import_pinned_key <asc-file> <fingerprint>: add a vendored key to pacman's
# keyring and locally sign it, after checking its fingerprint.
import_pinned_key() {
  local file="$1" fpr="$2" got
  got=$(gpg --homedir "$(mktemp -d)" --batch --show-keys --with-colons "$file" 2>/dev/null |
    awk -F: '/^fpr/ { print $10; exit }')
  [[ $got == "$fpr" ]] || die "$file has fingerprint '$got', upstream.lock pins '$fpr'"
  pacman-key --add "$file"
  pacman-key --lsign-key "$fpr"
}

# Run a command as the unprivileged package builder (makepkg refuses root).
as_builder() {
  runuser -u "$BUILDER_USER" -- env HOME="$BUILDER_HOME" MAKEFLAGS="-j$(build_jobs)" "$@"
}

ensure_builder() {
  if ! id -u "$BUILDER_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$BUILDER_HOME" --shell /bin/bash "$BUILDER_USER"
  fi
  install -m 0440 /dev/stdin "/etc/sudoers.d/90-$BUILDER_USER" <<EOF
$BUILDER_USER ALL=(root) NOPASSWD: /usr/bin/pacman
EOF
}
