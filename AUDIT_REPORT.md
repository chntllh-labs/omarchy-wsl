# Omarchy WSL: supply-chain, root filesystem and runtime audit

**Scope:** the `.wsl` images built from this repository (Basecamp Omarchy
v4.5.0, arm64 and x86_64), the build pipeline that produces them, and the
Windows/Linux runtime tools they ship.
**Method:** every claim below is enforced by a script or test in this
repository and named next to the claim. Nothing here is a one-off manual
finding. Run `make test` (or `make test-container`) and
`scripts/build-reproducible-rootfs.sh <arch> --verify-determinism --self-test-leak`
followed by `scripts/smoke-test-image.sh dist/<asset>` to reproduce it.

## 1. Threat model

| Risk | Where it would come from | Control |
|------|--------------------------|---------|
| Tampered base system | Stage 0 rootfs download | HTTPS only, plus a detached signature checked with `gpgv` against a vendored key whose fingerprint is pinned in `upstream.lock` (`Containerfile`, stages `rootfs-arm64` and `rootfs-amd64`) |
| Tampered Omarchy packages | `[omarchy]` (unsigned database) | `SigLevel = Required DatabaseOptional`, HTTPS-only server, the pinned key `40DFB630…C571` trusted before the first sync (`build/01-bootstrap.sh`); every Omarchy-published package must resolve to `[omarchy]` (`build/02-omarchy-repo.sh`) |
| Tampered upstream source | GitHub fetch of Omarchy | exact commit `a948d8a6…`, re-checked with the sha256 makepkg uses for git sources (`build/03-omarchy-wsl.sh`, PKGBUILD `prepare()`) |
| Builder secrets in the image | build context, build users | `.dockerignore`; build-only user removed; `scripts/strip-rootfs.sh` scrubs credentials in every home; `tests/audit-rootfs-leaks.sh` runs on the exact tree that is archived and fails closed |
| Shared machine identity | baked `machine-id`, keyring, SSH host keys | empty `/etc/machine-id`; no `/etc/pacman.d/gnupg` (created per install on first boot); no SSH host keys, random seed, `resolv.conf` or `hostname` (audit) |
| Lost permissions or capabilities | archiving on a non-Linux host | archives are normalised as root inside a Linux container (`scripts/normalize-rootfs.sh`); setuid `sudo`, sticky `/tmp`/`/var/tmp`, numeric owners and `security.capability` are asserted on synthetic and real images |
| Silent drift between repository and image | hand-maintained COPY lists | `rootfs.manifest` is the only install list; `tests/test_rootfs_manifest.py` fails on any uninstalled runtime file; the image verifies itself against the recorded sha256/mode (`make verify-rootfs`, `omarchy-doctor`) |

## 2. Build-time gates (the image does not build if one fails)

| Gate | Script |
|------|--------|
| Stage 0 signature + pinned key fingerprint | `Containerfile` |
| Pinned Omarchy key imported and locally signed before any sync | `build/01-bootstrap.sh` |
| Omarchy packages come from `[omarchy]`; `omarchy-keyring` carries the pinned key; `yay`/`mise` are native binaries | `build/02-omarchy-repo.sh` |
| Upstream tree checksum; `make verify-rootfs` after `make install-rootfs`; `omarchy-version` equals the lock | `build/03-omarchy-wsl.sh` |
| `/etc/os-release` branded and not a symlink | `build/04-configure-wsl.sh` |
| `omarchy-theme-set` works against upstream's headless mode; bridge round-trip keeps comments; `terminal-profile.json` matches the bridge; WSL 1 MiB file limit; `systemd-analyze verify` reports no unknown key on any shipped unit; gcc links | `build/05-verify.sh` |
| Shipped `pacman.conf` keeps the sandbox, `NoExtract` only under `[options]` | `build/99-cleanup.sh` |
| Leak and integrity audit on the archived tree, fail closed | `scripts/normalize-rootfs.sh` → `tests/audit-rootfs-leaks.sh` |
| Archive under 800 MiB; optional byte-identical second normalisation and seeded-leak self-test | `scripts/build-reproducible-rootfs.sh` |

## 3. Image gates (on the shipped `.wsl`, in CI and by hand)

`scripts/smoke-test-image.sh` imports the archive itself and checks:
- `pacman -Sy` with the shipped sandbox (Landlock + `DownloadUser = alpm`);
- a C program compiles and links;
- `sudo` is 4755, and `/tmp` and `/var/tmp` are 1777;
- file capabilities survive (`newuidmap` keeps `cap_setuid`), and unprivileged ping works;
- `/usr/lib/wsl/oobe.sh --headless --user devuser` creates uid 1000 with a valid sudo rule, linger and the default user, and a re-run is a no-op;
- `omarchy-version`, the full manifest and `pacman -Qkk omarchy-wsl` all pass;
- `systemd-analyze verify` of `build.slice` reports no unknown key;
- `omarchy-wsl` is the only foreign package, and root is locked without a hash.

`release.yml` adds per-path archive checks (required files present; runtime,
keyring, credential and home paths absent; `sudo`, `/tmp`, `/var/tmp` modes),
`actions/attest@v4` SLSA build provenance per asset, and a keyless cosign
bundle over `SHA256SUMS`.

## 4. Remediation of the earlier audit

The previous version of this file claimed "Verified & Remediated". Several of
those claims were not true: no Omarchy was installed, the `[omarchy-wsl]`
repository did not exist, static archives were deleted so gcc could not link,
the export flattened setuid bits, the slice units used invalid keys, and the
test counts were hard-coded. The table maps every finding of the 2026-11
audits to its resolution.

| Area | Findings | Resolution | Proof |
|------|----------|------------|-------|
| Image contents | Omarchy never installed; about 30 runtime files never copied; dead `[omarchy-wsl]` repository; `wsl-distribution.conf` pointing at missing files; no `.ico` | `omarchy-wsl` package (upstream v4.5.0 + WSL layer) owns every file through `rootfs.manifest`; `[omarchy]` replaces the dead repository; `/usr/lib/wsl/{oobe.sh,omarchy.ico,terminal-profile.json}` | `tests/test_rootfs_manifest.py`, `build/05-verify.sh`, smoke test |
| Base and trust | plain-HTTP, unverified ALARM tarball; floating `archlinux:base-devel`; `alarm` user on uid 1000; root password `root`; AUR builds at floating HEAD; `NoExtract` appended into `[aur]` | signed Stage 0 rootfs over HTTPS; board packages, `/boot` and `alarm` removed; root locked with `!*`; prebuilt `yay`/`mise-bin`/`omarchy-nvim` from `[omarchy]`; upstream pacman templates | `tests/test_upstream_lock.py`, audit integrity checks |
| Sanitiser and export | `libc_nonshared.a`/libgcc deleted; `.config/gh` never matched; docs of the image deleted; re-tar flattened setuid, sticky bits and ownership; `stat` fallback broke the size check; audit hard-coded one home | rewritten `strip-rootfs.sh`; normalisation as root in a Linux container with the deterministic GNU tar recipe; audit over every home with integrity checks and a seeded-leak self-test | `tests/test_build_pipeline.sh`, `--verify-determinism`, `--self-test-leak` |
| CI | build script bypassed; OR-grep archive check; wrong asset names; no tests run; release job permissions too broad | `release.yml` runs the strict suites, the reproducible build, per-path checks, smoke gates, attestations and signing, with least-privilege jobs; `ci.yml` on pull requests | workflow files |
| OOBE and accounts | interrupted OOBE exited 0; prompts captured by `$(...)`; renames uid 1000 back; `--user` renames the owner; `%wheel NOPASSWD`; `passwd -d`; locale-dependent transliteration; `--require-password` ignored; unbounded sync calls; no lock | prompts on `/dev/tty`; INT/TERM/HUP exit 128+n; the owner is uid 1000 (a re-run is a no-op, a different `--user` is refused with exit 3 and a pointer to `omarchy-rename-owner`); owner-only sudo rule, no `%wheel NOPASSWD`, every drop-in through `visudo`; `passwd -l`, never `-d`; NFKD + table transliteration identical on glibc and macOS; `--require-password` honoured; bounded sync calls; `flock`; shared `lib/omarchy-wsl-account.sh`; journaled, rollback-safe `omarchy-rename-owner` (see `docs/OOBE-SPECIFICATION.md`) | `tests/test_oobe_adversarial.sh`, `tests/unit/test_oobe_adversarial.py`, `tests/test_rename_owner.sh` |
| Build governance | `systemd-run --property=MemoryOOMGroup=yes` made `omarchy-build` exit 1; `-j`/`PATH` never reached the unit; invalid `[Slice]` keys; virtiofs bypassed the DrvFs guard; power governor halved builds on battery-less mini-PCs | `systemd-run --user --scope` with valid properties (the scope inherits the computed `-j` and `PATH`), only valid `[Slice]` keys, the shared DrvFs check (virtiofs included), battery detection fixed, failed Windows queries negative-cached | `tests/test_build_governance.sh`, `systemd-analyze` gate |
| Bridges and network tools | stale `$WSL_INTEROP` never healed; ssh-agent lock fd leaked into socat; proxy value written unquoted into `profile.d`; CA sync interpolated a Linux path into PowerShell and trusted broad name matches; DNS state `source`d as root; mirror ranking overwrote the list with blank servers; `netdoctor --repair` called an undefined function; migration gate aborted on the first pending migration; theme backups not locked | `omw_fix_interop` swaps a dead `$WSL_INTEROP` for the newest live socket; lock fd closed before socat; proxy values grammar-checked and single-quoted (hostile values exit 3); CA sync reads `LocalMachine\Root` by SHA-256, honours Disallowed and prunes; DNS sync validates IPs, parses state, never adds public resolvers unless asked; mirror ranking never writes an empty list; `netdoctor --repair` works; migration gate counts with `$((n + 1))`; theme writes are lock-protected (12×15 concurrent syncs lose nothing). Details: `docs/WINDOWS-INTEGRATION-QOL.md`, `docs/WSL-NETWORKING-AND-DNS-ADVERSARIAL-REVIEW.md`, `docs/THEME-ENGINE.md` | `tests/test_windows_integration.sh`, `tests/test_networking_adversarial.sh`, `tests/test_network_sync.sh`, `tests/test_migration_gate.sh`, pytest theme suites |
| Windows side | `.wslconfig` generator overwrote the file, put `hostAddressLoopback`/`ignoredPorts` in `[wsl2]`, never set `instanceIdleTimeout`; `.sh` generator sized from guest RAM; `install.ps1` used `exit` under `irm \| iex`; winget manifest used a non-existent `InstallerType: wsl`; `sync-theme.ps1` replaced profiles named like schemes | Server profile with both idle timeouts and a merge-not-overwrite writer; `.sh` generator removed; autostart task script; `install.ps1` throws/returns and verifies `SHA256SUMS`; `distributions/DistributionInfo.fragment.json` replaces winget; structural theme upsert | `tests/test_windows_tools.ps1`, `tests/test_memory_governance.py`, PowerShell parse gate |
| Isolation | interop and DrvFs are per distribution, not per Linux user, so "restrict interop to a group" is not implementable | `omarchy-tenant` gives guests a real boundary (user namespace, private network, cgroup egress filter, no WSL mounts) | `tests/test_tenant.sh`, `docs/MULTI-TENANT-ISOLATION.md` |

## 5. Known limits

- A live `wsl --install --from-file` on Windows (registration, Start menu
  entry, Windows Terminal profile, first-launch OOBE prompts) is not exercised
  by CI. The container smoke test runs the same OOBE headless inside the built
  Arch image (real `useradd`, `visudo`, linger); the suites' real-root tier
  runs on the Ubuntu test image.
- The x86_64 image is built and gated by `release.yml` on a native x86_64
  runner. The arm64 image is additionally built and smoke-tested on native
  arm64 hardware.
- `omarchy-tenant`'s generated isolation profile is unit-tested (rendered
  files, argv, refusal paths). A booted tenant with live egress tests is
  future work (`docs/MULTI-TENANT-ISOLATION.md`).
- Builds are deterministic for a given export, not across days: the Arch and
  `[omarchy]` repositories roll forward.
- WSL interop and DrvFs are per distribution. Every Linux account in the
  distribution can call Windows programs as the Windows user and read the
  Windows profile (files are 0744); use `omarchy-tenant` for untrusted users.
