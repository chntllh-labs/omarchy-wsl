# Dual-architecture build engine

How `Omarchy-arm64.wsl` and `Omarchy-x86_64.wsl` are produced, what each step
trusts, and how an installed system is updated. Everything here is implemented
in `Containerfile`, `build/`, `scripts/` and `packages/`. The tests named at the
end of each section enforce it.

## 1. Inputs and trust

`upstream.lock` pins every external input in one place. Shell code parses it as
plain `KEY=value` lines and never sources it.

| Input | Pin | Verified by |
|-------|-----|-------------|
| Basecamp Omarchy | `v4.5.0`, commit `a948d8a6…` (the `_commit` that `omacom-io/omarchy-pkgs` builds 4.5.0 from) | sha256 of `git archive --format tar <commit>` (`bf3220fc…`), the same check makepkg applies to git sources |
| `[omarchy]` repository | `https://pkgs.omarchy.org/stable/$arch` | packages must carry a signature from `40DFB630FF42BCFFB047046CF0134EE680CAC571` (`SigLevel = Required DatabaseOptional`; the database is unsigned, so the server is HTTPS-only) |
| Arch Linux ARM rootfs | `ArchLinuxARM-aarch64-latest.tar.gz` from `fl.us.mirror.archlinuxarm.org` (HTTPS) | detached `.sig`, checked with `gpgv` against the vendored key `68B3537F39A313B3E574D06777193F152BDBE6A6` |
| Arch Linux bootstrap (x86_64) | `iso/latest/archlinux-bootstrap-x86_64.tar.zst` from `geo.mirror.pkgbuild.com` | detached `.sig`, `gpgv` against `3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C` |
| Arch mirrors | Omarchy's stable snapshots (`arm-stable-mirror.omarchy.org`, `stable-mirror.omarchy.org`), HTTPS fallbacks | pacman signature checks against `archlinuxarm-keyring` / `archlinux-keyring` |

The three public keys live in `wsl/keys/`. Every consumer checks the key's
fingerprint before using it, so a swapped file fails the build. See
`wsl/keys/README.md` for where each key came from. `scripts/bump-upstream`
moves the Omarchy pin. It reads upstream's own `omarchy` PKGBUILD, refuses
versions that `[omarchy]` does not publish for both architectures yet,
re-verifies the checksum, then rewrites `upstream.lock` and the `omarchy-wsl`
PKGBUILD together.

Tests: `tests/test_upstream_lock.py` (pins, fingerprints, PKGBUILD/pacman.conf
agreement).

## 2. Stages

```
rootfs-arm64 (alpine)  curl over HTTPS → gpgv → bsdtar -xp as root ──┐
rootfs-amd64 (alpine)  curl over HTTPS → gpgv → bsdtar -xp as root ──┤
                                                                     ▼
base-<arch> (scratch + verified rootfs) → build  (one RUN per step, exported as is)
```

`build` is the image that gets exported. There is no final `COPY --from` into
`scratch`, so setuid bits and file capabilities reach `docker export` intact.

| Step | Script | What it does |
|------|--------|--------------|
| 01 | `build/01-bootstrap.sh` | installs `wsl/pacman/pacman.conf.<arch>` (upstream Omarchy's stable template: `[omarchy]` first, `NoExtract` under `[options]`, no ALARM `[aur]`) and the HTTPS mirrorlist; relaxes the sandbox, `DownloadUser` and `CheckSpace` for the container build only; initialises the keyring and trusts the pinned Omarchy key **before** the first sync; removes ALARM's board packages, `/boot` and the `alarm` user (uid 1000); locks root with `!*` (no hash); `pacman -Syu`; installs `packages/omarchy-wsl-base.packages` |
| 02 | `build/02-omarchy-repo.sh` | asserts `omarchy-keyring`, `omarchy-nvim`, `yay`, `mise-bin` and `ttf-jetbrains-mono-nerd-basic` resolve to `[omarchy]`; installs the keyring (checks that it carries the pinned key) and those packages, then `packages/omarchy-wsl-tools.packages`; checks that `yay` and `mise` are native binaries for the architecture. Nothing is compiled from the AUR. |
| 03 | `build/03-omarchy-wsl.sh` | fetches exactly the pinned upstream commit (depth 1, not the 1.2 GB history), re-verifies its checksum, builds the `omarchy-wsl` package with makepkg as an unprivileged builder, `pacman -U`, then `make install-rootfs DESTDIR=/` and `make verify-rootfs` |
| 04 | `build/04-configure-wsl.sh` | masks `systemd-resolved`, `systemd-networkd(+socket, wait-online)`, `systemd-network-generator`, `systemd-timesyncd`, `systemd-firstboot`, `tmp.mount`; enables `omarchy-pacman-init.service` and `docker.socket`; sets the `en_US.UTF-8` locale; checks the `/etc/os-release` branding |
| 05 | `build/05-verify.sh` | applies Tokyo Night with the WSL `omarchy-theme-set` against upstream's headless mode, starts Neovim headless, round-trips the theme bridge on a scratch Windows Terminal profile, compares `/usr/lib/wsl/terminal-profile.json` with the bridge's rendering, enforces WSL's 1 MiB read limit, runs `systemd-analyze verify` on every shipped unit (any "unknown" key fails the build), and links a C program |
| 99 | `build/99-cleanup.sh` | removes the builder, orphans and caches; reinstalls the shipped `pacman.conf` (sandbox and `DownloadUser` back on) and fails if `NoExtract` sits outside `[options]`; deletes the build keyring; runs `scripts/strip-rootfs.sh` |

No user account exists in the image. The OOBE (`/usr/lib/wsl/oobe.sh`) creates
uid 1000 on first launch, and `omarchy-pacman-init.service` creates a keyring
with a unique local master key on first boot.

## 3. Package sources

| Set | File | Source |
|-----|------|--------|
| Base system | `packages/omarchy-wsl-base.packages` | Arch Linux / Arch Linux ARM |
| CLI tools, toolchains, Docker, fonts | `packages/omarchy-wsl-tools.packages` | Arch Linux / Arch Linux ARM |
| Omarchy-published | `packages/omarchy-wsl-omarchy.packages` | `[omarchy]`, prebuilt for both architectures |
| Omarchy CLI, themes, defaults + WSL layer | `packages/PKGBUILDs/omarchy-wsl` | built in step 03 from the pinned upstream commit and this repository |
| Optional, not in the image | `packages/omarchy-wsl-extras.packages` | heavier toolchains (clang/llvm, Go, Rust, Ruby) and the proprietary `claude-code`, installed on demand to keep the image within its size budget and redistributable |

`omarchy-wsl` `provides=omarchy` and conflicts with upstream's `omarchy` and
`omarchy-settings`, which depend on Hyprland, SDDM, Limine and Snapper. It ships
upstream's `bin/ default/ config/ install/ migrations/ themes/` under
`/usr/share/omarchy` (theme wallpapers dropped) with every command symlinked
into `/usr/bin`. The WSL replacements for `omarchy-update`, `omarchy-doctor`,
`omarchy-theme-set` and `omarchy-version` are installed over those symlinks. It
also ships upstream's terminal-relevant `/etc/skel` configs and migration
markers, and this repository's whole WSL layer through `rootfs.manifest`, so
pacman owns every file.

## 4. One manifest for the root filesystem

`rootfs.manifest` lists every file this repository installs: source glob, mode,
destination, and whether the `omarchy-wsl` package owns it (`pkg`) or it belongs
to another package (`rootfs`, today only `/etc/os-release`). Admin-editable
configuration is marked `config`, and the PKGBUILD must list exactly those
entries in `backup=()`.

- `make install-pkg DESTDIR=…` is what the PKGBUILD runs.
- `make install-rootfs DESTDIR=…` installs 100% of it (step 03 runs it with `DESTDIR=/`).
- `make verify-rootfs ROOT=…` / `/usr/lib/omarchy-wsl/install-manifest --verify /`
  re-checks every installed file's sha256 and mode, and the presence and mode of
  config files. The build runs it, as do `omarchy-doctor` and the CI smoke test.

Tests: `tests/test_rootfs_manifest.py` fails when a tracked runtime file is
neither installed nor excluded, when an installed file differs from its source,
mode or link target, when stray files appear, or when `backup=()` drifts.

## 5. Export, audit and determinism

`scripts/build-reproducible-rootfs.sh <arm64|x86_64>` builds the image (on the
host network, since a WSL host's DNS-tunnel resolver is unreachable from bridge
networks), exports it, and hands the export to `scripts/normalize-rootfs.sh`
**as root inside a Linux container**. The host never unpacks the rootfs, so it
works from macOS too, where bsdtar would drop setuid/sticky bits, system uids
and file capabilities. The normaliser:

1. extracts with `--numeric-owner --xattrs --xattrs-include=security.capability`;
2. drops the runtime's `/.dockerenv`, `/etc/resolv.conf`, `/etc/hostname` and
   `/dev` entries, and empties `/etc/machine-id`;
3. runs `tests/audit-rootfs-leaks.sh` on the exact tree it will archive
   (credentials in any home, token patterns, build users, per-machine
   identity, caches, plus integrity: setuid `sudo`, sticky `/tmp` and
   `/var/tmp`, `libc_nonshared.a`, locked root). It refuses to write anything
   on failure;
4. archives with
   `LC_ALL=C tar --format=posix --pax-option=delete=atime,delete=ctime,exthdr.name=%d/PaxHeaders/%f --xattrs --xattrs-include=security.capability --numeric-owner --sort=name --mtime="@${SOURCE_DATE_EPOCH}"`
   piped to `gzip -n -9`.

`--verify-determinism` repeats the normalisation in a second container and
requires a byte-identical result. `--self-test-leak` seeds a private key, a
`gh` token and a `.netrc`, and requires the audit to fail with no artifact
written. The build fails if the archive exceeds 800 MiB.

The strip step (`scripts/strip-rootfs.sh`) never deletes static archives
(`libc.so` links `libc_nonshared.a`; gcc needs `libgcc.a`). It keeps
`/usr/share/doc/omarchy-wsl`, and removes only documentation and translations
that were unpacked before the `NoExtract` rules applied.

Tests: `tests/test_build_pipeline.sh` proves the determinism, permission,
capability and fail-closed guarantees on a synthetic export in seconds.
`scripts/smoke-test-image.sh` checks the real artifact (`pacman -Sy`, a gcc
link, `sudo` 4755, the headless OOBE, the manifest, `systemd-analyze`).

## 6. Updates on an installed system

- `omarchy update` → `omarchy-wsl-update`: checks that the pinned Omarchy key is
  trusted and that `[omarchy]` is wired, without editing `pacman.conf`. It then
  runs one `pacman -Syu`, which updates `omarchy-keyring`, `omarchy-nvim`, `yay`,
  `mise-bin` and the Arch packages, followed by upstream migrations through the
  WSL migration gate, mise, Neovim plugins and the user's `post-update` hook.
  `--check` reports without changing anything, and `--repair-pacman` restores
  the shipped `pacman.conf` and mirrorlist with backups.
- The `omarchy-wsl` package itself is not published in a binary repository.
  `omarchy-wsl-update --self [vX.Y.Z]` rebuilds it from a release tag of this
  repository with the same pinned, checksum-verified recipe the image uses.
- `/etc/os-release` belongs to the `filesystem` package. A libalpm hook
  re-applies the Omarchy WSL branding after any transaction that reinstalls
  it.

## 7. Reproducing a build

```bash
# Linux with Docker or Podman (native arm64 or x86_64 host)
scripts/build-reproducible-rootfs.sh arm64 --verify-determinism --self-test-leak
scripts/smoke-test-image.sh dist/Omarchy-arm64.wsl
```

`SOURCE_DATE_EPOCH` defaults to the last commit time. The archive is
deterministic for a given export: two normalisations produce the same bytes.
Two builds on different days are not expected to match, because the Arch and
`[omarchy]` repositories roll forward.
