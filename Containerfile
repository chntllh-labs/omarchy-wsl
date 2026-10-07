# syntax=docker/dockerfile:1.4
# ==============================================================================
# Omarchy WSL: Production Multi-Stage Reproducible Containerfile
# ==============================================================================
# Dual-Architecture: ARM64 (aarch64) and AMD64 (x86_64)
# Enforces unprivileged AUR compilation, strict NoExtract stripping,
# offline-safe pacman keyring pre-population, and zero-leak sanitization.
# ==============================================================================

ARG ARCH=arm64
ARG SOURCE_DATE_EPOCH=1775000000

# ------------------------------------------------------------------------------
# Stage 0: Arch Linux ARM Bootstrap (ARM64 only)
# ------------------------------------------------------------------------------
FROM alpine:3.20 AS arm64-bootstrap
ARG TARGETARCH
RUN apk add --no-cache curl tar gzip ca-certificates
RUN mkdir -p /alarm-rootfs && \
    curl -fSL -o /tmp/alarm.tar.gz http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz && \
    tar --numeric-owner -xpzf /tmp/alarm.tar.gz -C /alarm-rootfs && \
    rm -f /tmp/alarm.tar.gz

# ------------------------------------------------------------------------------
# Base Architecture Selector
# ------------------------------------------------------------------------------
FROM scratch AS base-arm64
COPY --from=arm64-bootstrap /alarm-rootfs/ /

FROM archlinux:base-devel AS base-amd64

FROM base-${ARCH} AS base-platform
ARG ARCH
ARG SOURCE_DATE_EPOCH

# ------------------------------------------------------------------------------
# Stage 1: Isolated Unprivileged AUR & Toolchain Builder
# ------------------------------------------------------------------------------
FROM base-platform AS builder-aur
ARG ARCH
ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

# Disable Landlock and prepare pacman sandbox bypass
RUN sed -i 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf || true && \
    grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf && \
    if [ "$ARCH" = "arm64" ]; then \
      pacman-key --init && pacman-key --populate archlinuxarm && \
      pacman -Sy --noconfirm --needed archlinuxarm-keyring; \
    else \
      pacman-key --init && pacman-key --populate archlinux && \
      pacman -Sy --noconfirm --needed archlinux-keyring; \
    fi && \
    pacman -Sy --noconfirm --needed base-devel git sudo ca-certificates

COPY scripts/makepkg-governor.sh /usr/local/bin/makepkg-governor
RUN chmod +x /usr/local/bin/makepkg-governor

# Create unprivileged build user
RUN useradd -m -u 1001 -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder && \
    mkdir -p /packages && chown -R builder:builder /packages

USER builder
WORKDIR /home/builder

# Compile yay-bin / yay under governor
RUN git clone --depth 1 https://aur.archlinux.org/yay-bin.git /home/builder/yay-bin && \
    cd /home/builder/yay-bin && \
    makepkg-governor light -- makepkg -s --noconfirm && \
    cp *.pkg.tar.zst /packages/

# Compile / package mise-bin under governor
RUN git clone --depth 1 https://aur.archlinux.org/mise-bin.git /home/builder/mise-bin && \
    cd /home/builder/mise-bin && \
    makepkg-governor light -- makepkg -s --noconfirm && \
    cp *.pkg.tar.zst /packages/

# ------------------------------------------------------------------------------
# Stage 2: Rootfs Assembly & Configuration
# ------------------------------------------------------------------------------
FROM base-platform AS rootfs-assembly
ARG ARCH
ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

# 1. Enforce NoExtract rules in pacman.conf to eliminate doc/man/locale bloat at install time
RUN sed -i '/^#NoExtract/s/^#//' /etc/pacman.conf || true && \
    echo 'NoExtract = usr/share/help/* usr/share/doc/* usr/share/gtk-doc/* usr/share/info/* usr/share/locale/* !usr/share/locale/en* !usr/share/locale/locale.alias' >> /etc/pacman.conf && \
    echo 'ParallelDownloads = 8' >> /etc/pacman.conf

# 2. Synchronize repositories and install base system
COPY packages/omarchy-wsl-base.packages /tmp/base.packages
COPY packages/omarchy-wsl-tools.packages /tmp/tools.packages

RUN pacman -Syu --noconfirm --needed $(cat /tmp/base.packages /tmp/tools.packages | grep -v '^#' | grep -v '^$') && \
    rm -f /tmp/base.packages /tmp/tools.packages

# 3. Install Stage 1 compiled AUR packages
COPY --from=builder-aur /packages /tmp/packages
RUN pacman -U --noconfirm /tmp/packages/*.pkg.tar.zst && \
    rm -rf /tmp/packages

# 3b. Wire up dual-arch pacman repository configuration for rolling updates
RUN printf '\n[omarchy-wsl]\nSigLevel = Required DatabaseOptional\nServer = https://pkgs.omarchy-wsl.org/%s\nServer = https://raw.githubusercontent.com/omacom-io/omarchy-wsl-pkgs/gh-pages/%s\n' "${ARCH}" "${ARCH}" >> /etc/pacman.conf

# 4. Inject WSL Configuration, Services, and Scripts
COPY wsl/wsl.conf /etc/wsl.conf
COPY wsl/wsl-distribution.conf /etc/wsl-distribution.conf
COPY wsl/sysctl.d/99-omarchy-wsl.conf /etc/sysctl.d/99-omarchy-wsl.conf
COPY wsl/pacman-init.sh /usr/lib/omarchy-wsl/pacman-init.sh
COPY wsl/omarchy-pacman-init.service /usr/lib/systemd/system/omarchy-pacman-init.service
COPY wsl/oobe.sh /usr/lib/omarchy-wsl/oobe.sh

RUN chmod 0755 /usr/lib/omarchy-wsl/*.sh && \
    systemctl enable omarchy-pacman-init.service

# 4b. Windows Integration & QoL tooling (docs/WINDOWS-INTEGRATION-QOL.md)
#     User-facing commands land in /usr/bin; interop bridges live in the curated
#     /usr/lib/omarchy-wsl/bin shim directory (on PATH via profile.d), never in
#     a Windows %PATH% append.
COPY lib/omarchy-wsl-interop.sh /usr/lib/omarchy-wsl/interop.sh
COPY wsl/lib/drvfs-guard.sh /usr/lib/omarchy-wsl/drvfs-guard.sh
COPY bin/omarchy-open bin/omarchy-clip bin/omarchy-notify bin/omarchy-sync-dirs \
     bin/omarchy-docker-bridge bin/omarchy-watch-bridge bin/omarchy-power-governor \
     bin/omarchy-build /usr/bin/
COPY wsl/bin/omarchy-ssh-agent-bridge wsl/bin/omarchy-git-credential-bridge /usr/lib/omarchy-wsl/bin/
COPY wsl/profile.d/10-omarchy-wsl-path.sh wsl/profile.d/20-omarchy-browser.sh \
     wsl/profile.d/20-omarchy-wslg-audio.sh wsl/profile.d/30-omarchy-ssh-agent.sh \
     wsl/profile.d/40-omarchy-drvfs-guard.sh wsl/profile.d/50-omarchy-docker.sh /etc/profile.d/
COPY wsl/etc/pulse/client.conf.d/wslg.conf /etc/pulse/client.conf.d/wslg.conf
COPY wsl/etc/alsa/conf.d/99-omarchy-wslg-pulse.conf /etc/alsa/conf.d/99-omarchy-wslg-pulse.conf
COPY wsl/environment.d/50-omarchy-wslg.conf /usr/lib/environment.d/50-omarchy-wslg.conf
COPY wsl/tmpfiles.d/user/omarchy-wslg.conf /usr/share/user-tmpfiles.d/omarchy-wslg.conf
COPY wsl/systemd/user/omarchy-ssh-agent-bridge.service /usr/lib/systemd/user/omarchy-ssh-agent-bridge.service
COPY wsl/share/nvim/omarchy-clipboard.lua /usr/share/omarchy/nvim/omarchy-clipboard.lua
COPY wsl/share/tmux/omarchy-clipboard.conf /usr/share/omarchy/tmux/omarchy-clipboard.conf
COPY assets/notify/ /usr/share/omarchy/notify/
COPY docs/WINDOWS-INTEGRATION-QOL.md /usr/share/doc/omarchy-wsl/WINDOWS-INTEGRATION-QOL.md
RUN chmod 0755 /usr/bin/omarchy-open /usr/bin/omarchy-clip /usr/bin/omarchy-notify \
               /usr/bin/omarchy-sync-dirs /usr/bin/omarchy-docker-bridge /usr/bin/omarchy-watch-bridge \
               /usr/bin/omarchy-power-governor /usr/bin/omarchy-build \
               /usr/lib/omarchy-wsl/bin/omarchy-ssh-agent-bridge /usr/lib/omarchy-wsl/bin/omarchy-git-credential-bridge && \
    chmod 0644 /usr/lib/omarchy-wsl/interop.sh /usr/lib/omarchy-wsl/drvfs-guard.sh /etc/profile.d/*.sh

# 5. Mask problematic services that conflict with WSL2 virtualization
RUN systemctl mask systemd-resolved.service \
                   systemd-networkd.service \
                   systemd-networkd.socket \
                   systemd-timesyncd.service \
                   systemd-firstboot.service

# 6. Pre-initialize and populate pacman keyring offline
RUN /usr/lib/omarchy-wsl/pacman-init.sh

# ------------------------------------------------------------------------------
# Stage 3: Adversarial Rootfs Sanitization & Stripping
# ------------------------------------------------------------------------------
FROM rootfs-assembly AS sanitizer
ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

COPY scripts/strip-rootfs.sh /tmp/strip-rootfs.sh
RUN chmod +x /tmp/strip-rootfs.sh && \
    /tmp/strip-rootfs.sh && \
    rm -f /tmp/strip-rootfs.sh

# ------------------------------------------------------------------------------
# Stage 4: Clean Export Rootfs
# ------------------------------------------------------------------------------
FROM scratch AS final
COPY --from=sanitizer / /

LABEL org.opencontainers.image.title="Omarchy-WSL" \
      org.opencontainers.image.description="Pristine, reproducible, hardened Omarchy distribution for WSL2" \
      org.opencontainers.image.authors="Nous Research & Omarchy Project" \
      org.opencontainers.image.source="https://github.com/nousresearch/omarchy-wsl"

ENV LANG=en_US.UTF-8 \
    SHELL=/bin/bash

CMD ["/bin/bash"]
