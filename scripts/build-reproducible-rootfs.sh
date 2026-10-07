#!/bin/bash
# ==============================================================================
# Omarchy WSL: Reproducible Distro Build & Packaging Pipeline
# ==============================================================================
# Builds multi-stage container, exports rootfs, enforces deterministic archiving,
# runs adversarial leak tests, and verifies compressed size <800MB.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *)
    echo "[-] ERROR: Unsupported architecture '$ARCH'" >&2
    exit 1
    ;;
esac

# 1. Determine SOURCE_DATE_EPOCH for reproducible builds
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_DATE_EPOCH=$(git -C "$ROOT_DIR" log -1 --pretty=%ct)
  else
    SOURCE_DATE_EPOCH=1775000000 # Deterministic fallback
  fi
fi
export SOURCE_DATE_EPOCH

# 2. Select Container Engine (podman, docker, wslc)
if command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
elif command -v wslc.exe >/dev/null 2>&1; then
  ENGINE="wslc.exe"
else
  echo "[-] ERROR: No container engine found (podman, docker, or wslc.exe required)." >&2
  exit 1
fi

DIST_DIR="${ROOT_DIR}/dist"
mkdir -p "$DIST_DIR"

IMAGE_TAG="omarchy-wsl:${ARCH}-${SOURCE_DATE_EPOCH}"
OUTPUT_WSL="${DIST_DIR}/Omarchy-${ARCH}.wsl"

echo "========================================================================"
echo " Omarchy-WSL Reproducible Build Engine"
echo "========================================================================"
echo " Target Architecture : $ARCH"
echo " Container Engine    : $ENGINE"
echo " SOURCE_DATE_EPOCH   : $SOURCE_DATE_EPOCH"
echo " Output Package      : $OUTPUT_WSL"
echo "========================================================================"

# 3. Build Container Image
echo "[+] Step 1: Building multi-stage container image..."
$ENGINE build \
  --build-arg ARCH="$ARCH" \
  --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  -t "$IMAGE_TAG" \
  -f "${ROOT_DIR}/Containerfile" \
  "$ROOT_DIR"

# 4. Export Rootfs
echo "[+] Step 2: Exporting rootfs container layer..."
CONTAINER_ID=$($ENGINE create "$IMAGE_TAG")
TMP_TAR="${DIST_DIR}/.tmp-rootfs.tar"
$ENGINE export "$CONTAINER_ID" -o "$TMP_TAR"
$ENGINE rm "$CONTAINER_ID" >/dev/null

# 5. Adversarial Leak & Integrity Verification on Raw Archive
echo "[+] Step 3: Executing adversarial leak & integrity audit on export archive..."
AUDIT_FAILED=0

check_forbidden_path() {
  local pattern="$1"
  local desc="$2"
  if tar -tf "$TMP_TAR" | grep -E "$pattern" >/dev/null 2>&1; then
    echo "  [!] FAIL: Leak detected: $desc ($pattern)" >&2
    AUDIT_FAILED=1
  else
    echo "  [✓] PASS: No $desc found"
  fi
}

check_forbidden_path "^(root|home/[^/]+)/\.ssh/" "leaked SSH keys"
check_forbidden_path "^(root|home/[^/]+)/\.gnupg/" "leaked personal GPG keys"
check_forbidden_path "^(root|home/[^/]+)/\.claude/" "leaked Claude credentials"
check_forbidden_path ".*_history$" "leaked shell history"
check_forbidden_path "^var/cache/pacman/pkg/.+" "unpurged pacman package caches"
check_forbidden_path "^var/lib/systemd/random-seed" "non-reproducible random seed"
check_forbidden_path "^etc/pacman\.d/gnupg/S\." "stale GPG agent sockets"
check_forbidden_path "^etc/sudoers\.d/(builder|makepkg|aur)" "residual build-user sudoers"
check_forbidden_path "^usr/lib/wsl/" "leaked host GPU driver mounts"

# Check machine-id is empty (0 bytes)
MACHINE_ID_SIZE=$(tar -tvf "$TMP_TAR" etc/machine-id 2>/dev/null | awk '{print $3}' || echo "missing")
if [[ "$MACHINE_ID_SIZE" == "0" ]]; then
  echo "  [✓] PASS: /etc/machine-id is clean and exactly 0 bytes"
else
  echo "  [!] FAIL: /etc/machine-id is size '$MACHINE_ID_SIZE' (expected 0 bytes)" >&2
  AUDIT_FAILED=1
fi

if (( AUDIT_FAILED != 0 )); then
  echo "[-] ERROR: Adversarial audit failed! Aborting packaging." >&2
  rm -f "$TMP_TAR"
  exit 1
fi

# 6. Compress with Reproducible Flags
echo "[+] Step 4: Compressing reproducible distribution package..."
COMPRESSOR="gzip -n -9"
if command -v pigz >/dev/null 2>&1; then
  COMPRESSOR="pigz -n -9"
fi

# Re-tar with strict reproducible ordering and timestamps
mkdir -p "${DIST_DIR}/.repro-unpack"
tar -xf "$TMP_TAR" -C "${DIST_DIR}/.repro-unpack"
rm -f "$TMP_TAR"

(
  cd "${DIST_DIR}/.repro-unpack"
  tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - . | $COMPRESSOR > "$OUTPUT_WSL"
)

rm -rf "${DIST_DIR}/.repro-unpack"

# 7. Footprint Budget Verification (<800MB)
FILE_SIZE_BYTES=$(stat -f "%z" "$OUTPUT_WSL" 2>/dev/null || stat -c "%s" "$OUTPUT_WSL")
FILE_SIZE_MB=$(( FILE_SIZE_BYTES / 1024 / 1024 ))
MAX_BUDGET_MB=800

echo "========================================================================"
echo " Distribution Artifact Built Successfully"
echo " Artifact Path : $OUTPUT_WSL"
echo " Package Size  : ${FILE_SIZE_MB} MB (Budget: < ${MAX_BUDGET_MB} MB)"
echo " SHA256 Hash   : $(sha256sum "$OUTPUT_WSL" | awk '{print $1}')"
echo "========================================================================"

if (( FILE_SIZE_MB > MAX_BUDGET_MB )); then
  echo "[-] WARNING: Artifact size (${FILE_SIZE_MB}MB) exceeds 800MB budget!" >&2
  exit 1
else
  echo "[+] SUCCESS: Artifact strictly within footprint budget."
fi
