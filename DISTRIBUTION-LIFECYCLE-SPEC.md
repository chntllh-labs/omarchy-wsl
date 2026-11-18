# Omarchy-WSL: Distribution, Installation, Update and Release Lifecycle

This document describes how Omarchy-WSL reaches a Windows machine and how it is
kept up to date: release artifacts and their verification, the installer, host
configuration (`.wslconfig`), autostart, and updates. Each section names the
file that implements it; when this document and a script disagree, the script
wins and this document has a bug.

Status words used below:

- **Shipped**: implemented in this repository and covered by tests.
- **Manual**: a documented procedure; no script automates it.
- **Not supported**: considered and rejected, with the reason.

---

## 1. Release artifacts and verification

A release is a GitHub release of `chntllh-labs/omarchy-wsl` tagged `v*`, built by
`.github/workflows/release.yml`. It carries:

| Asset | Content |
| :--- | :--- |
| `Omarchy-x86_64.wsl` | Root filesystem for x64 Windows (gzip-compressed tar with a `.wsl` extension) |
| `Omarchy-arm64.wsl` | Root filesystem for Windows on ARM64 |
| `SHA256SUMS` | GNU `sha256sum` lines for the release files |
| `SHA256SUMS.sigstore.json` | Sigstore (cosign keyless) bundle signing `SHA256SUMS` |

The workflow also records SLSA build provenance for the images with
`actions/attest@v4` (GitHub artifact attestations).

Three levels of checking, from weakest to strongest:

1. **Integrity** (what the installer always does): the image's SHA-256 must
   match `SHA256SUMS` from the same release. This proves the download is
   complete and unmodified in transit. Because both files come from the same
   release, it does not prove who built them.
2. **Build provenance**: proves the image was built by this repository's
   workflow.

   ```powershell
   gh attestation verify Omarchy-x86_64.wsl --repo chntllh-labs/omarchy-wsl
   ```

   The installer runs this automatically with `-VerifyAttestation` (needs the
   GitHub CLI, signed in) and refuses to install if it fails.
3. **Signed checksums**: proves `SHA256SUMS` was signed by the release workflow
   for a `v*` tag; then check the image against it with `sha256sum -c`.

   ```bash
   cosign verify-blob --bundle SHA256SUMS.sigstore.json \
     --certificate-identity-regexp 'https://github.com/chntllh-labs/omarchy-wsl/.github/workflows/release.yml@refs/tags/v.*' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     SHA256SUMS
   ```

Microsoft's own image checks (`distributions/validate-modern.py` in
microsoft/WSL) can be run against a built image; see `distributions/README.md`.

---

## 2. Installation channels

| Channel | Status | How |
| :--- | :--- | :--- |
| One-line PowerShell installer | Shipped | `irm https://raw.githubusercontent.com/chntllh-labs/omarchy-wsl/main/install/install.ps1 \| iex` |
| Manual download | Shipped | Download the image and `SHA256SUMS` from the release, check them (section 1), then `wsl --install --from-file Omarchy-<arch>.wsl --name Omarchy` (WSL 2.4.4 or later) |
| `wsl --install Omarchy` | Not listed | The entry for Microsoft's distribution manifest is prepared in `distributions/DistributionInfo.fragment.json`. It needs real hashes and Microsoft's review; see `distributions/README.md`. |
| winget | Not supported | winget's installer schema (checked up to v1.28.0) has no `wsl` installer type and none of its types registers a WSL distribution. |
| MSIX / Microsoft Store | Not supported | `.wsl` files replaced appx packaging for WSL distributions; an MSIX would also need a trusted code-signing certificate. |

To pass installer parameters, run it as a script block:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/chntllh-labs/omarchy-wsl/main/install/install.ps1))) -DistroName Omarchy-Dev -VerifyAttestation
```

---

## 3. The installer (`install/install.ps1`)

Status: **Shipped**. Works in Windows PowerShell 5.1 and PowerShell 7.

| Step | Behaviour | Failure handling |
| :--- | :--- | :--- |
| Host check | 64-bit Windows 10 2004 (build 19041) or later, `wsl.exe` present | Stops with the fix (`wsl --install --no-distribution` in an elevated prompt, then reboot). The installer never elevates itself. |
| Elevation | WSL registers distributions per Windows user, so an elevated window installs for the wrong account if you elevated as another user | Warns and asks before continuing (`-NonInteractive`: warns only) |
| Architecture | `Omarchy-arm64.wsl` if any probe reports ARM64 (machine-level `PROCESSOR_ARCHITECTURE`, `PROCESSOR_ARCHITEW6432`, `PROCESSOR_ARCHITECTURE`, `RuntimeInformation.OSArchitecture`), else `Omarchy-x86_64.wsl`. ARM64 is found even from emulated x64 PowerShell. | x86-only hosts are refused |
| Name collision | If the name exists: [1] update in place (`omarchy-update` inside it), [2] install a second copy under a new name, [3] cancel | `-NonInteractive` stops unless `-ForceSideBySide` (installs as `<Name>-1`, `-2`, ...) |
| Release | Resolves `latest` (or `-ReleaseTag`) to a tag through the GitHub API, then downloads `SHA256SUMS` and the image from that tag | Missing asset or API error stops the install |
| Integrity | SHA-256 of the image must equal its `SHA256SUMS` line (exact file name match) | Mismatch or missing line: nothing is installed, temp files are deleted |
| Provenance | `-VerifyAttestation` runs `gh attestation verify`; otherwise the `gh` and `cosign` commands from section 1 are printed | Failure stops the install |
| Install | WSL 2.4.4 or later: `wsl --install --from-file <image> --name <Name>` (`--location`, `--no-launch` when asked). This runs the distribution's first-start setup (OOBE). | Registered but first start failed: stops with `wsl -d` / `wsl --unregister` guidance. Not registered: falls back to `wsl --import`. |
| Older WSL | `wsl --import <Name> %LOCALAPPDATA%\wsl\<Name> <image> --version 2` | WSL skips the OOBE for imported distributions; Omarchy's first-boot profile hook runs the setup on the first interactive root login (`wsl -d <Name> -u root`). The installer prints this. |
| Health check | `wsl -d <Name> -u root --exec uname -r` | Stops with the exit code |

Other properties:

- **Never calls `exit`.** Under `irm | iex` that would close the user's
  PowerShell window. Errors are terminating errors, so
  `powershell -File install.ps1` still exits non-zero.
- **TLS:** adds TLS 1.2 on Windows PowerShell 5.1 when .NET is not already
  using the OS defaults; the progress bar is disabled for the download.
- **Temporary files** live in a fresh directory under `%TEMP%` and are removed
  on success and failure.

---

## 4. Host configuration: `.wslconfig` (`tools/generate-wslconfig.ps1`)

Status: **Shipped**. `.wslconfig` is per Windows user and applies to every WSL 2
distribution of that user. The generator:

- **Sizes from the Windows host** (CIM: installed RAM, logical processors),
  never from inside a guest, which only sees what WSL already granted.
- **Merges, never overwrites.** Only managed keys are written. Unknown
  sections, unmanaged keys, comments and blank lines are kept. A managed key in
  the wrong section, an old `[experimental]` spelling of a promoted key, or a
  duplicate of a managed key is commented out with a reason, not deleted.
  Unknown or misplaced unmanaged keys are reported and left alone.
- **Shows a unified diff** and writes only with `-Force` or after an
  interactive "y". `-DryRun` writes nothing and prints the resulting file.
- **Backs up** the previous file as `.wslconfig.bak-<yyyyMMdd-HHmmss>`, writes
  a temporary file in the same directory and replaces the original with it.
- **Encoding:** UTF-8 without BOM, CRLF line endings. WSL opens `.wslconfig` in
  text mode with `ccs=UTF-8`, so a BOM or LF endings would also be read; CRLF
  matches what WSL Settings writes. UTF-16 files (with BOM) are read and
  rewritten as UTF-8.
- **Never runs `wsl --shutdown`.** New settings apply at the next VM start.

### Profiles

| Key | Desktop (default) | Server |
| :--- | :--- | :--- |
| `[wsl2] memory`, `swap`, `processors` | sized from the host | same |
| `[wsl2] guiApplications` | `true` | `false` (`-KeepGui` keeps `true`) |
| `[wsl2] vmIdleTimeout` | left as is (WSL default 60000 ms) | `-1` |
| `[general] instanceIdleTimeout` | left as is (WSL default 15000 ms) | `-1` |

The Server profile is for a headless, always-on host reached over SSH. Both
idle timeouts are required: with `vmIdleTimeout=-1` alone, WSL still stops the
distribution 15 s after its last process exits (`instanceIdleTimeout`), which
takes systemd services, tmux, containers and sshd down with it; a negative
value disables idle termination for that level (WSL source,
`LxssUserSession.cpp`). `guiApplications=false` skips the WSLg system
distribution (Weston, XWayland, PulseAudio and its RDP connection), which a
host nobody looks at does not need.

### Networking

| Windows build | Keys |
| :--- | :--- |
| 22621+ (Windows 11 22H2) and no `-ForceNAT` | `[wsl2] networkingMode=mirrored`, `dnsTunneling=true`, `firewall=true`, `autoProxy=true`; `[experimental] hostAddressLoopback=true`, `ignoredPorts=5353,5355` |
| Older, or `-ForceNAT` | `[wsl2] networkingMode=NAT`, `dnsTunneling=false`, `autoProxy=false`, `localhostForwarding=true` |

`localhostForwarding` is never written in mirrored mode (WSL ignores it there);
`hostAddressLoopback` and `ignoredPorts` are never written in NAT mode (mirrored
only). `nestedVirtualization=true` is written only on x64 Windows 11, never on
ARM64. Every mode also writes `[experimental] autoMemoryReclaim=gradual` and
`sparseVhd=false`.

### Sizing

| Host RAM | WSL memory | Swap |
| :--- | :--- | :--- |
| up to 8 GB | half (at least 2 GB) | 4 GB |
| up to 18 GB | 8 GB | 4 GB |
| up to 36 GB | RAM - 8 GB | 8 GB |
| up to 72 GB | 75 % | 16 GB |
| more | RAM - 16 GB | 16 GB |

Presets (`-HardwarePreset Laptop-16GB | Pro-32GB | Workstation-64GB |
Server-128GB`) and overrides (`-RamOverrideGB`, `-CpuOverride`,
`-SwapOverrideGB`) are clamped: memory to host RAM minus `-WindowsReserveGB`
(default 4), processors to the host count, swap to at least 4 GB.

### Key placement

Verified on 2026-11-18 against
<https://learn.microsoft.com/en-us/windows/wsl/wsl-config> (page dated
2026-10-16) and microsoft/WSL `src/windows/common/WslCoreConfig.{h,cpp}`:

| Section | Keys this repository writes |
| :--- | :--- |
| `[wsl2]` | `memory`, `processors`, `swap`, `nestedVirtualization`, `guiApplications`, `vmIdleTimeout`, `networkingMode`, `dnsTunneling`, `firewall`, `autoProxy`, `localhostForwarding` |
| `[general]` | `instanceIdleTimeout` |
| `[experimental]` | `autoMemoryReclaim`, `sparseVhd`, `hostAddressLoopback`, `ignoredPorts` |

`networkingMode`, `dnsTunneling`, `firewall` and `autoProxy` were promoted to
`[wsl2]`; WSL still reads their old `[experimental]` spelling as an alias.
`autoMemoryReclaim`, `sparseVhd`, `hostAddressLoopback` and `ignoredPorts` exist
only under `[experimental]`: under `[wsl2]` WSL reports "Unknown key" and
ignores them. `pageReporting` is not a current WSL key. `wsl/wslconfig.example`
is the generator's output for a 32 GB x64 host, and the tests keep it in sync.

---

## 5. Starting WSL automatically (`tools/register-wsl-autostart.ps1`)

Status: **Shipped**. Registers (or `-Unregister`s) a Task Scheduler task that
runs `wsl.exe -d <Distro> --exec /bin/true`, which boots the WSL VM and the
distribution so systemd services are up before the first terminal opens.
`-DryRun` prints the task definition (Task Scheduler XML) and changes nothing.

- **At logon** (default): runs as you with your interactive token while you are
  logged on. No administrator rights, no stored password.
- **At boot** (`-AtStartup`): needs an elevated PowerShell (boot triggers are
  administrator-only) and a logon type that works without a session:
  - `S4U` (default): no password stored; the task has no network credentials,
    and some WSL builds may refuse to start a distribution from such a token.
  - `Password`: Task Scheduler stores your password; works like a normal
    logon, but breaks when the password changes until you register again.
  WSL keys instances by user, so a later interactive `wsl.exe` attaches to the
  instance the task started.
- **How long it stays up** is set by `.wslconfig`: with the Server profile
  (both idle timeouts `-1`) the short `/bin/true` run is enough. Otherwise use
  `-KeepAlive`, which adds `--exec /bin/sleep infinity` and lifts the task's
  time limit.
- **No console window:** the task uses `%ProgramFiles%\WSL\wslg.exe` when
  present (same arguments as `wsl.exe`, but a GUI-subsystem program), else
  `%SystemRoot%\System32\wsl.exe`.
- After `wsl --shutdown` the distribution stays down until the next trigger or
  `Start-ScheduledTask`.

---

## 6. Updating an installed distribution

WSL stores a distribution in one `ext4.vhdx`; there is no separate `/home`
disk. Re-importing an image over an existing name would therefore erase the
user's files, so the supported update path never does that.

### 6.1 In place: `omarchy-update` (Shipped)

Run inside the distribution:

```bash
omarchy-update        # same as `omarchy update`; add -y to skip confirmations
```

`omarchy-update` is the WSL replacement for upstream Omarchy's command and runs
`omarchy-wsl-update`: a preflight (disk space, pacman lock, the pinned Omarchy
signing key), one `pacman -Syu`, then per-user steps (optional AUR updates with
`--aur`, upstream migrations through the WSL migration gate, mise tools, Neovim
plugins, the post-update hook) and a verification pass. The migration gate
(`lib/omarchy-wsl-migration-gate`) replaces bootloader, udev/modprobe and
display-manager calls with logged no-ops, snapshots `~/.bashrc`, `~/.config`
and `~/.XCompose` before the first pending migration, re-applies the Omarchy
WSL sysctls afterwards and runs migrations as the user, never against `/root`.
The scripts' headers (`wsl/overlay/bin/omarchy-update`,
`bin/omarchy-wsl-update`, `lib/omarchy-wsl-migration-gate`) are the reference
for the exact steps and options.

### 6.2 Re-base onto a new image (Manual)

For a release that cannot be reached by package updates. No script ships for
this; replace `<user>` with your Linux user name (`wsl -d Omarchy -- whoami`).

1. Full backup, kept until the new install is verified (`wsl --export` does
   not create the folder):
   `mkdir C:\WSL` and `wsl --export Omarchy C:\WSL\Omarchy-backup.tar`
2. Archive the home directory:
   `wsl -d Omarchy -u root -- tar -cpf /mnt/c/WSL/omarchy-home.tar -C /home <user>`
3. Remove the old registration: `wsl --unregister Omarchy`
4. Install the new release under the same name (installer or
   `wsl --install --from-file`) and create the same user name in its first-start
   setup.
5. Restore the home directory:
   `wsl -d Omarchy -u root -- tar -xpf /mnt/c/WSL/omarchy-home.tar -C /home`
6. If the user's UID or GID changed:
   `wsl -d Omarchy -u root -- chown -R <user>:<user> /home/<user>`
7. Check your files, then delete the two archives.

If anything goes wrong after step 3, `wsl --import Omarchy <folder> C:\WSL\Omarchy-backup.tar`
brings the old distribution back.

### 6.3 Separate `/home` disk (Not supported)

`wsl --mount --vhd` attaches a disk to the WSL VM, but it needs an elevated
prompt and must be repeated after every VM start, so a `/home` on its own VHDX
cannot be made reliable from inside the distribution. Use section 6.2 with
`wsl --export` backups instead.

---

## 7. End-to-end flow

```
irm .../install.ps1 | iex
  -> host check ............ stop with the fix (no elevation, no exit)
  -> name taken? ........... update in place (omarchy-update) | second copy | cancel
  -> resolve release tag ... GitHub API
  -> download + SHA-256 .... SHA256SUMS from the same tag; mismatch: stop, delete
  -> [gh attestation verify] with -VerifyAttestation
  -> wsl --install --from-file (2.4.4+, runs the OOBE) | wsl --import (first-boot hook)
  -> boot check
optional, on the Windows side:
  -> tools/generate-wslconfig.ps1 [-Profile Server]   (diff, -Force, backup)
  -> tools/register-wsl-autostart.ps1 [-AtStartup] [-KeepAlive]
later, inside the distribution:
  -> omarchy-update
```

---

## 8. Files

| File | Purpose |
| :--- | :--- |
| `install/install.ps1` | One-line installer (section 3) |
| `tools/generate-wslconfig.ps1` | `.wslconfig` generator and merger (section 4) |
| `wsl/wslconfig.example` | Generator output for a 32 GB x64 host, annotated |
| `tools/register-wsl-autostart.ps1` | Autostart task (section 5) |
| `distributions/DistributionInfo.fragment.json` | Entry for Microsoft's WSL distribution manifest |
| `distributions/README.md` | Filling in release hashes, validating with Microsoft's script, submitting |
| `wsl/overlay/bin/omarchy-update`, `bin/omarchy-wsl-update` | In-place update (section 6.1) |
| `lib/omarchy-wsl-migration-gate` | Upstream migrations under WSL (section 6.1) |
| `.github/workflows/release.yml` | Builds and publishes the release assets (section 1) |
| `tests/test_windows_tools.sh`, `tests/test_windows_tools.ps1` | Tests for the Windows-side tools in this document |
