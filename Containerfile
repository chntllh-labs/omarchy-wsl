# syntax=docker/dockerfile:1
# ==============================================================================
# Omarchy for WSL: dual-architecture root filesystem
# ==============================================================================
#   scripts/build-reproducible-rootfs.sh arm64     -> dist/Omarchy-arm64.wsl
#   scripts/build-reproducible-rootfs.sh x86_64    -> dist/Omarchy-x86_64.wsl
#
# Stages
#   rootfs-arm64   Arch Linux ARM tarball over HTTPS, signature verified with
#                  gpgv against the vendored ALARM build key pinned in
#                  upstream.lock (68B3537F...E6A6), unpacked as root.
#   rootfs-amd64   Arch Linux bootstrap tarball, signature verified against the
#                  vendored release key pinned in upstream.lock (3E80CA1A...9A5C).
#   base-<arch>    The verified stock rootfs as one layer.
#   build          build/NN-*.sh, one layer per step: pacman bootstrap and trust,
#                  [omarchy] packages, the omarchy-wsl package (upstream Omarchy
#                  v4.5.0 + this repository via `make install-pkg`), `make
#                  install-rootfs`, WSL configuration, verification probes, and
#                  sanitisation. It is the exported image: no final COPY stage, so
#                  setuid bits and file capabilities reach `docker export` intact.
#
# The exporter (scripts/normalize-rootfs.sh) removes the runtime's
# /etc/resolv.conf and /etc/hostname, audits the tree for leaks and archives it
# deterministically as root inside a Linux container.
# ==============================================================================

ARG ARCH=arm64

# ------------------------------------------------------------------------------
# Stage 0: verified stock root filesystems
# ------------------------------------------------------------------------------
FROM docker.io/library/alpine:3.22 AS rootfs-arm64
COPY upstream.lock /verify/upstream.lock
COPY wsl/keys/archlinuxarm-build-system.asc /verify/key.asc
RUN set -eu; \
    apk add --no-cache curl gnupg libarchive-tools; \
    lock() { sed -n "s/^$1=//p" /verify/upstream.lock; }; \
    url=$(lock ALARM_ROOTFS_URL); fpr=$(lock ALARM_KEY_FPR); \
    case "$url" in https://*) ;; *) echo "refusing non-HTTPS rootfs URL $url" >&2; exit 1 ;; esac; \
    curl -fsSL --retry 3 --proto '=https' -o /verify/rootfs.tar.gz "$url"; \
    curl -fsSL --retry 3 --proto '=https' -o /verify/rootfs.tar.gz.sig "$url.sig"; \
    export GNUPGHOME=/verify/gnupg; install -d -m 0700 "$GNUPGHOME"; \
    got=$(gpg --batch --show-keys --with-colons /verify/key.asc | awk -F: '/^fpr/{print $10; exit}'); \
    [ "$got" = "$fpr" ] || { echo "ALARM key fingerprint $got != pinned $fpr" >&2; exit 1; }; \
    gpg --batch --dearmor </verify/key.asc >/verify/key.gpg; \
    gpgv --keyring /verify/key.gpg /verify/rootfs.tar.gz.sig /verify/rootfs.tar.gz; \
    mkdir /rootfs; \
    bsdtar -xpf /verify/rootfs.tar.gz -C /rootfs --numeric-owner; \
    rm -rf /verify

FROM docker.io/library/alpine:3.22 AS rootfs-amd64
COPY upstream.lock /verify/upstream.lock
COPY wsl/keys/archlinux-release-pierre-schmitz.asc /verify/key.asc
RUN set -eu; \
    apk add --no-cache curl gnupg libarchive-tools zstd; \
    lock() { sed -n "s/^$1=//p" /verify/upstream.lock; }; \
    url=$(lock ARCH_BOOTSTRAP_URL); fpr=$(lock ARCH_BOOTSTRAP_KEY_FPR); \
    case "$url" in https://*) ;; *) echo "refusing non-HTTPS bootstrap URL $url" >&2; exit 1 ;; esac; \
    curl -fsSL --retry 3 --proto '=https' -o /verify/bootstrap.tar.zst "$url"; \
    curl -fsSL --retry 3 --proto '=https' -o /verify/bootstrap.tar.zst.sig "$url.sig"; \
    export GNUPGHOME=/verify/gnupg; install -d -m 0700 "$GNUPGHOME"; \
    got=$(gpg --batch --show-keys --with-colons /verify/key.asc | awk -F: '/^fpr/{print $10; exit}'); \
    [ "$got" = "$fpr" ] || { echo "bootstrap key fingerprint $got != pinned $fpr" >&2; exit 1; }; \
    gpg --batch --dearmor </verify/key.asc >/verify/key.gpg; \
    gpgv --keyring /verify/key.gpg /verify/bootstrap.tar.zst.sig /verify/bootstrap.tar.zst; \
    mkdir /unpack; \
    bsdtar -xpf /verify/bootstrap.tar.zst -C /unpack --numeric-owner; \
    mv /unpack/root.x86_64 /rootfs; \
    rm -rf /verify /unpack

FROM scratch AS base-arm64
COPY --from=rootfs-arm64 /rootfs/ /

FROM scratch AS base-amd64
COPY --from=rootfs-amd64 /rootfs/ /

# ------------------------------------------------------------------------------
# Build: one RUN per step so a later step rebuilds without re-downloading the
# package layers.
# ------------------------------------------------------------------------------
FROM base-${ARCH} AS build
ARG ARCH
ARG SOURCE_DATE_EPOCH=0
ARG OMARCHY_WSL_GIT_SHA=unknown
ARG PACMAN_MIRROR=
ARG MAKE_JOBS=
ENV OMARCHY_BUILD_ROOT=/opt/omarchy-wsl-build \
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    OMARCHY_WSL_GIT_SHA=${OMARCHY_WSL_GIT_SHA} \
    PACMAN_MIRROR=${PACMAN_MIRROR} \
    MAKE_JOBS=${MAKE_JOBS} \
    LANG=C.UTF-8
WORKDIR /opt/omarchy-wsl-build

COPY upstream.lock ./
COPY build/lib.sh build/01-bootstrap.sh build/
COPY wsl/keys/ wsl/keys/
COPY wsl/pacman/ wsl/pacman/
COPY packages/omarchy-wsl-base.packages packages/
RUN bash build/01-bootstrap.sh

COPY build/02-omarchy-repo.sh build/
COPY packages/ packages/
RUN bash build/02-omarchy-repo.sh

# Everything the omarchy-wsl package and rootfs.manifest install.
COPY Makefile rootfs.manifest LICENSE README.md ./
COPY bin/ bin/
COPY lib/ lib/
COPY wsl/ wsl/
COPY tools/ tools/
COPY assets/ assets/
COPY docs/ docs/
COPY scripts/ scripts/
COPY build/03-omarchy-wsl.sh build/
RUN bash build/03-omarchy-wsl.sh

COPY build/04-configure-wsl.sh build/
RUN bash build/04-configure-wsl.sh

COPY build/05-verify.sh build/
RUN bash build/05-verify.sh

COPY build/99-cleanup.sh build/
RUN bash build/99-cleanup.sh && rm -rf /opt/omarchy-wsl-build

LABEL org.opencontainers.image.title="Omarchy WSL" \
      org.opencontainers.image.description="Omarchy (Basecamp, v4.5.0) packaged as a Windows Subsystem for Linux distribution" \
      org.opencontainers.image.source="https://github.com/chntllh-labs/omarchy-wsl" \
      org.opencontainers.image.url="https://github.com/chntllh-labs/omarchy-wsl" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="chntllh-labs"

ENV LANG=en_US.UTF-8
WORKDIR /
CMD ["/bin/bash", "-l"]
