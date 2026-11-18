#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: build the image and export a deterministic, audited .wsl file
# ==============================================================================
#   scripts/build-reproducible-rootfs.sh <arm64|x86_64> [options]
#
#   --skip-build            reuse the already built image omarchy-wsl:<arch>
#   --verify-determinism    normalise the export twice, in two separate
#                           containers, and require byte-identical output
#   --self-test-leak        normalise once more with seeded leaks and require
#                           the audit to fail closed (no artifact written)
#   --keep-export           keep dist/.export-<arch>.tar
#   --output DIR            output directory (default: dist/)
#   -h, --help
#
# Environment: CONTAINER_ENGINE (docker|podman), SOURCE_DATE_EPOCH (default:
# last commit time), OMARCHY_WSL_GIT_SHA, NORMALIZE_IMAGE (default
# debian:bookworm-slim: GNU tar + gzip), MAX_SIZE_MB (default 800),
# PACMAN_MIRROR, MAKE_JOBS, AUDIT_EXTRA_PATTERNS.
#
# Outputs dist/Omarchy-arm64.wsl or dist/Omarchy-x86_64.wsl plus .sha256.
# Archiving runs as root inside a Linux container (scripts/normalize-rootfs.sh):
# the host never extracts the rootfs, so setuid/sticky bits, numeric uids and
# security.capability survive on any host, including macOS.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '5,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() {
  echo "[build] ERROR: $*" >&2
  exit 1
}
log() { echo "[build] $*"; }

ARCH_ARG=""
SKIP_BUILD=0 VERIFY_DETERMINISM=0 SELF_TEST_LEAK=0 KEEP_EXPORT=0
DIST_DIR="$ROOT_DIR/dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --verify-determinism) VERIFY_DETERMINISM=1 ;;
    --self-test-leak) SELF_TEST_LEAK=1 ;;
    --keep-export) KEEP_EXPORT=1 ;;
    --output)
      DIST_DIR="${2:?--output needs a directory}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "[build] unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *) ARCH_ARG="$1" ;;
  esac
  shift
done

case "${ARCH_ARG:-$(uname -m)}" in
  arm64 | aarch64) ARCH=arm64 PLATFORM=linux/arm64 ASSET=Omarchy-arm64.wsl ;;
  x86_64 | amd64) ARCH=amd64 PLATFORM=linux/amd64 ASSET=Omarchy-x86_64.wsl ;;
  *) die "unsupported architecture '$ARCH_ARG' (arm64 or x86_64)" ;;
esac

if [[ -z ${SOURCE_DATE_EPOCH:-} ]]; then
  SOURCE_DATE_EPOCH=$(git -C "$ROOT_DIR" log -1 --format=%ct 2>/dev/null || echo 0)
fi
export SOURCE_DATE_EPOCH
OMARCHY_WSL_GIT_SHA="${OMARCHY_WSL_GIT_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
NORMALIZE_IMAGE="${NORMALIZE_IMAGE:-docker.io/library/debian:bookworm-slim}"
MAX_SIZE_MB="${MAX_SIZE_MB:-800}"

ENGINE="${CONTAINER_ENGINE:-}"
if [[ -z $ENGINE ]]; then
  if command -v docker >/dev/null 2>&1; then ENGINE=docker
  elif command -v podman >/dev/null 2>&1; then ENGINE=podman
  else die "docker or podman is required"; fi
fi

IMAGE_TAG="omarchy-wsl:$ARCH"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
EXPORT_TAR="$DIST_DIR/.export-$ARCH.tar"
OUTPUT="$DIST_DIR/$ASSET"

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

CID=""
cleanup() {
  [[ -n $CID ]] && $ENGINE rm -f "$CID" >/dev/null 2>&1 || true
  if ((KEEP_EXPORT == 0)); then rm -f "$EXPORT_TAR"; fi
  rm -f "$DIST_DIR/.determinism-"*.wsl "$DIST_DIR/.leaktest.wsl"
}
trap cleanup EXIT

echo "========================================================================"
echo " Omarchy WSL reproducible build"
echo "   architecture     $ARCH ($PLATFORM)"
echo "   engine           $ENGINE"
echo "   SOURCE_DATE_EPOCH $SOURCE_DATE_EPOCH"
echo "   git              $OMARCHY_WSL_GIT_SHA"
echo "   output           $OUTPUT"
echo "========================================================================"

if ((SKIP_BUILD == 0)); then
  log "building $IMAGE_TAG"
  $ENGINE build --platform "$PLATFORM" \
    --build-arg ARCH="$ARCH" \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --build-arg OMARCHY_WSL_GIT_SHA="$OMARCHY_WSL_GIT_SHA" \
    --build-arg PACMAN_MIRROR="${PACMAN_MIRROR:-}" \
    --build-arg MAKE_JOBS="${MAKE_JOBS:-}" \
    -t "$IMAGE_TAG" -f "$ROOT_DIR/Containerfile" "$ROOT_DIR"
fi

log "exporting the root filesystem"
CID=$($ENGINE create --platform "$PLATFORM" "$IMAGE_TAG" /bin/true)
$ENGINE export -o "$EXPORT_TAR" "$CID"
$ENGINE rm -f "$CID" >/dev/null
CID=""

normalize() {
  local out="$1" seed="${2:-0}"
  $ENGINE run --rm \
    -v "$DIST_DIR:/work" \
    -v "$ROOT_DIR/scripts:/scripts:ro" \
    -v "$ROOT_DIR/tests:/tests:ro" \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -e SEED_LEAK="$seed" \
    -e AUDIT_EXTRA_PATTERNS="${AUDIT_EXTRA_PATTERNS:-}" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$NORMALIZE_IMAGE" bash /scripts/normalize-rootfs.sh "/work/$(basename "$EXPORT_TAR")" "/work/$(basename "$out")"
}

log "normalising, auditing and packing (inside $NORMALIZE_IMAGE)"
normalize "$OUTPUT"
SUM=$(sha256 "$OUTPUT")

if ((VERIFY_DETERMINISM)); then
  log "determinism: second independent normalisation of the same export"
  normalize "$DIST_DIR/.determinism-2.wsl"
  SUM2=$(sha256 "$DIST_DIR/.determinism-2.wsl")
  if [[ $SUM2 != "$SUM" ]]; then
    die "non-deterministic archive: $SUM vs $SUM2"
  fi
  log "determinism: PASS (both runs sha256 $SUM)"
fi

if ((SELF_TEST_LEAK)); then
  log "leak self-test: seeded leaks must make the audit fail closed"
  if normalize "$DIST_DIR/.leaktest.wsl" 1; then
    die "leak self-test: the audit PASSED a rootfs with seeded leaks"
  fi
  [[ ! -e $DIST_DIR/.leaktest.wsl ]] || die "leak self-test: an artifact was written despite the failed audit"
  log "leak self-test: PASS (audit failed closed, no artifact)"
fi

SIZE_BYTES=$(file_size "$OUTPUT")
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
printf '%s  %s\n' "$SUM" "$ASSET" >"$OUTPUT.sha256"

echo "========================================================================"
echo " $ASSET"
echo "   size    $SIZE_BYTES bytes (${SIZE_MB} MiB, budget < ${MAX_SIZE_MB} MiB)"
echo "   sha256  $SUM"
echo "========================================================================"
((SIZE_MB < MAX_SIZE_MB)) || die "$ASSET is ${SIZE_MB} MiB, over the ${MAX_SIZE_MB} MiB budget"
