# Omarchy-WSL Distribution, Installation, Rolling Update & CI/CD Lifecycle Architecture

**Document ID:** ARCH-OMARCHY-WSL-001  
**Target Release:** Omarchy-WSL v4.0.0+ ("Quattro" Engine)  
**Security & Reliability Target:** Zero User-Data Loss, Full Dual-Arch Parity (x86_64 & arm64), Hardened WSL Virtualization  

---

## 1. Executive Summary & Adversarial Design Philosophy

The **Omarchy-WSL** distribution engine ports Basecamp's bleeding-edge Arch Linux / Omarchy development environment to Windows Subsystem for Linux (WSL). While conventional Linux distributions for WSL treat image creation as a one-off build step, an open-source distribution must solve the entire **post-installation lifecycle**:
1. **Effortless Community Onboarding:** A verifiable, single-command installation experience on Windows 10 and 11.
2. **Zero User-Data Loss:** In-place rolling updates that upgrade the operating system, package set, and upstream features without destroying user files in `/home/<user>`, SSH keys, local projects, shell history, or Docker state.
3. **Upstream Migration Resilience:** Safe replay of upstream Omarchy migration scripts designed for bare-metal Arch Linux, intercepting hardware-specific operations that would crash or hang WSL.
4. **Hardened Virtualization Stability:** Systemd unit masking, memory allocation protection, and sysctl ordering to avoid WSL kernel crashes and slab starvation.
5. **Dual-Architecture Native CI/CD:** GitHub Actions release pipelines building, validating, cryptographically signing, and distributing both `x86_64` and `arm64` (Qualcomm Snapdragon X Elite / Oryon) `.wsl` packages.

---

## 2. Attack Angle 1: One-Line Installation Engineering

### 2.1 Distribution Channel Evaluation Matrix

To deliver an effortless experience to the community, four installation vectors were adversarially evaluated:

| Channel | User Experience | Friction / Prerequisites | Failure Modes | Security / Integrity | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`irm https://... \| iex` (PowerShell Web Bootstrap)** | **Best** (1 command in PowerShell) | None (Built into Windows 10/11) | Script execution policy (`Restricted`), TLS 1.0/1.1 defaults in legacy PS 5.1 | High (Enforced TLS 1.2+, SHA-256 verification before import) | **Primary Channel** |
| **`winget install Omacom.OmarchyWSL`** | High (1 command if winget present) | Windows 11 / Windows 10 App Installer package | Winget review latency (24–72 hrs per release); WSL installer type compatibility variations | High (Microsoft moderated) | **Secondary Channel** (Storefront) |
| **MSIX / APPX Installer** | Moderate (Double-click GUI installer) | Requires Desktop App Installer | Certificate trust failure: Untrusted self-signed cert blocks install unless $300/yr EV cert is used | High (when signed) | **Rejected** (Unviable for OSS community) |
| **Manual GitHub `.wsl` Release Download** | Low (Manual download + terminal command) | Requires user to run `wsl --install --from-file` | Users often import into wrong path or as Administrator, creating orphaned profiles | High (Checksums provided) | **Direct Fallback Channel** |

---

### 2.2 Threat Model & Failure Mode Analysis for `irm ... | iex`

#### Threat 1: The Administrator / UAC Elevation Trap (Orphan Profile Bug)
- **Vulnerability:** Standard users frequently run PowerShell as Administrator when encountering setup scripts. If `wsl --import` or `wsl --install --from-file` executes inside an elevated Administrator shell, WSL registers the distribution under the Administrator user profile (`S-1-5-18` or `C:\Users\Administrator`).
- **Consequence:** When the user returns to their regular desktop and launches Windows Terminal or VS Code, the `Omarchy` distribution does not appear in their dropdown or registry.
- **Mitigation:** `install.ps1` explicitly checks `[Security.Principal.WindowsPrincipal]::IsInRole("Administrator")`. If elevated, it warns the user and requests running in standard user space. If WSL itself needs enabling (requiring admin rights), the script elevates *only* for the `dism` / `wsl --install --no-distribution` call, leaving distro registration strictly in the user's unprivileged session.

#### Threat 2: PowerShell 5.1 TLS & WebClient Deadlocks
- **Vulnerability:** In stock Windows PowerShell 5.1, `Invoke-WebRequest` defaults to SSLv3 / TLS 1.0 on some systems, causing GitHub API connections to fail. Furthermore, the default PowerShell progress bar (`$ProgressPreference = 'Continue'`) triggers massive GUI rendering overhead in the console host, slowing 800MB–1.5GB downloads by up to 10×.
- **Mitigation:** The script explicitly executes:
  ```powershell
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
  $ProgressPreference = 'SilentlyContinue'
  ```

#### Threat 3: Host Architecture Misidentification on Windows ARM64
- **Vulnerability:** Qualcomm Snapdragon X Elite and Surface Pro devices run ARM64 Windows. If a user runs 32-bit x86 PowerShell, `$env:PROCESSOR_ARCHITECTURE` reports `x86`, while `$env:PROCESSOR_ARCHITEW6432` reports `ARM64`. Naive installers download the `x86_64` image, which fails to run or causes sluggish translation.
- **Mitigation:** Multi-tiered architecture inspection:
  ```powershell
  $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  if ($rawArch -match "ARM64") { "arm64" } else { "x86_64" }
  ```

#### Threat 4: Distro Name Collision & Silent Destruction
- **Vulnerability:** A user with an existing `Omarchy` installation runs the installer again to "fix" or "re-install". Running a naive import would either fail cryptographically or destroy their virtual hard drive (`ext4.vhdx`).
- **Mitigation:** The installer queries `wsl.exe --list --quiet`. If `Omarchy` exists:
  1. It triggers an interactive Safety Gate.
  2. Offers **Option 1:** Seamless in-place rolling update (zero data loss via `omarchy-wsl-update`).
  3. Offers **Option 2:** Side-by-side installation under an isolated name (`Omarchy-1`).
  4. Offers **Option 3:** Abort without touching any files.

#### Threat 5: Checksum Mismatch and Corrupted Download
- **Vulnerability:** A flaky network drops connections mid-download, leaving a corrupt 400MB `.wsl` file that fails with cryptic WSL internal HRESULT errors (`0x80070057`).
- **Mitigation:** `install.ps1` downloads both `Omarchy-<arch>.wsl` and `SHA256SUMS`. It executes `Get-FileHash -Algorithm SHA256` and asserts an exact hexadecimal match before touching `wsl.exe`. On mismatch, the temporary directory is purged and the script fails closed.

---

## 3. Attack Angle 2: Zero-Data-Loss In-Place Rolling Updates

### 3.1 The Fundamental WSL Data-Loss Hazard

In Windows Subsystem for Linux:
$$\text{Distribution Rootfs} \subset \text{C:\textbackslash Users\textbackslash...\textbackslash LocalState\textbackslash ext4.vhdx}$$
When a user installs or imports a distribution archive (`.wsl` or `.tar`), WSL formats a fresh `ext4.vhdx` disk. **There is no separate `/home` partition by default.** If a maintainer instructs users to upgrade by running `wsl --import Omarchy ... new.wsl`, **every file in `/home/<user>` is erased**.

### 3.2 The Three Update Architectures

Omarchy-WSL designs three tiers of update architectures to address this:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   Omarchy-WSL Update Architecture                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
         ┌──────────────────────────┴──────────────────────────┐
         ▼                                                     ▼
┌─────────────────────────────────┐           ┌─────────────────────────────────┐
│     Tier 1: In-Place Rolling    │           │    Tier 2: Major Image Swap     │
│   (Standard 99% of Updates)     │           │   (Disaster Recovery/Major Rebase)
│                                 │           │                                 │
│ • pacman -Syu (Rolling Arch)    │           │ • Safe Home Tarball Backup      │
│ • Keyring auto-refresh          │           │ • Rootfs Re-import              │
│ • Git pull upstream Omarchy     │           │ • Restoration & UID Recalibrate │
│ • Migration Gate with shims     │           │ • Zero data lost in /home       │
│ • Sysctl order re-enforcement   │           └─────────────────────────────────┘
└─────────────────────────────────┘
```

#### Tier 1: In-Place Rolling Update (`omarchy-wsl-update`)
Because Arch Linux is a continuous rolling-release distribution, the OS does not require wiping the root filesystem to stay modern.
- **Keyring Hygiene:** Prevents pacman PGP verification errors:
  - x86_64: Refreshes `archlinux-keyring` and `omarchy-keyring`.
  - arm64: Refreshes `archlinuxarm-keyring`.
- **Sandbox Preservation:** Ensures `DisableSandbox` and commented `DownloadUser` are maintained in `/etc/pacman.conf` so Landlock seccomp filters do not break downloads.
- **Upstream Sync:** Fast-forwards `~/.local/share/omarchy` without discarding local working tree branches.
- **Migration Safety Gate:** Executes unapplied migrations through the virtualization shim (Section 4).
- **Toolchain Upgrades:** Executes `mise upgrade` and Neovim headless plugin sync (`nvim --headless "+Lazy! sync" +qa`).

#### Tier 2: Major Image Swap with Home Extraction (Re-base Engine)
When an upstream change breaks glibc or fundamentally changes disk layout, an automated PowerShell re-base script executes:
1. `wsl --terminate Omarchy`
2. Archive existing user data:
   `wsl -d Omarchy -u root -- tar -cpf /mnt/c/Users/<user>/AppData/Local/Temp/omarchy-home.tar -C /home aqua`
3. Export full safety backup: `wsl --export Omarchy C:\WSL\Omarchy-PreUpgrade.tar`
4. Re-import new `.wsl` image into `C:\WSL\Omarchy`.
5. Re-inject user home:
   `wsl -d Omarchy -u root -- tar -xpf /mnt/c/Users/<user>/AppData/Local/Temp/omarchy-home.tar -C /home`
6. Enforce ownership: `wsl -d Omarchy -u root -- chown -R aqua:aqua /home/aqua`
7. Delete temporary archive upon verification.

#### Tier 3: Declarative Split-VHDX Architecture (Advanced Optional Setup)
For enterprise or power users, Omarchy-WSL supports attaching an independent `home.vhdx`:
```powershell
# Create secondary virtual disk for persistent home
wsl --mount --vhd C:\WSL\Disks\omarchy-home.vhdx --name omarchy-home
```
Inside `/etc/fstab`:
```
/dev/disk/by-label/omarchy-home  /home  ext4  defaults,noatime  0  2
```
In this configuration, the root VHDX can be deleted and replaced at any time without touching `/home`.

---

## 4. Attack Angle 3: Upstream Migrations & WSL Virtualization Shims

### 4.1 Upstream Omarchy Migration Failure Modes in WSL

Upstream Omarchy migrations (`~/.local/share/omarchy/migrations/*.sh`) target bare-metal Arch Linux machines. When run inside WSL, they produce immediate failures:

1. **Bare-Metal Init & Display Managers:** Upstream scripts issue `systemctl restart sddm` or `systemctl restart bluetooth`. In WSL, SDDM is absent or masked; with `set -e`, the entire migration terminates with a non-zero exit code, leaving packages half-configured.
2. **Bootloader Tampering:** Upstream migrations run `limine enroll-config` or `bootctl update`. WSL has no UEFI or Limine bootloader; invoking these tools throws errors.
3. **Hardware Audio & Kernel Modules:** Upstream migrations execute `modprobe` or `udevadm trigger`. Inside a WSL2 container namespace, these fail without root capability or hardware access.
4. **Compositor Communication:** Migrations query `hyprctl` or `swaync-client`. In headless or terminal WSL sessions, the Wayland compositor socket does not exist.
5. **Dotfile Clobbering:** Migrations copy default configs over `~/.bashrc` or `~/.config/nvim/init.lua`, overwriting user aliases, environment variables, and customizations.
6. **The Sysctl Ordering Regression (Incident Retrospective 2026-09-10):**
   - Upstream Omarchy writes `/etc/sysctl.d/99-omarchy-sysctl.conf` with `vm.vfs_cache_pressure = 50` and `vm.swappiness = 150`.
   - In WSL with containerized workloads, `vfs_cache_pressure = 50` causes directory and inode caches to balloon uncontrollably, starving the kernel of order:0 pages and triggering `kswapd0` memory exhaustion and crashes.

---

### 4.2 The Virtualization Shim Layer (`omarchy-wsl-migration-gate`)

To neutralize these failure modes, Omarchy-WSL introduces `omarchy-wsl-migration-gate`. Before running any migration script, it injects a virtualization shim directory `/usr/lib/omarchy-wsl/shims` to the front of `$PATH`:

```
┌────────────────────────────────────────────────────────┐
│            Migration Execution Environment             │
└───────────────────────────┬────────────────────────────┘
                            │
            PATH="/usr/lib/omarchy-wsl/shims:$PATH"
                            │
    ┌───────────────────────┼───────────────────────┐
    ▼                       ▼                       ▼
┌──────────────┐    ┌──────────────┐        ┌──────────────┐
│  systemctl   │    │  bootloaders │        │  compositor  │
│  (Shimmed)   │    │  (Shimmed)   │        │  (Shimmed)   │
│              │    │              │        │              │
│ Filters sddm,│    │ limine,      │        │ hyprctl,     │
│ bluetooth,   │    │ bootctl,     │        │ swaync-client│
│ NetworkMgr;  │    │ udevadm,     │        │ Check active │
│ no-op exit 0 │    │ modprobe -> 0│        │ display; safe│
└──────────────┘    └──────────────┘        └──────────────┘
```

#### User Dotfile Protection & 3-Way Splitting
To eliminate configuration clobbering:
1. `~/.bashrc` is structured as a loader:
   ```bash
   # Upstream Omarchy environment bootstrap
   source "$OMARCHY_PATH/default/bashrc"

   # Immutable user override hook
   [[ -f ~/.bashrc.local ]] && source ~/.bashrc.local
   ```
2. User customizations live strictly in `~/.bashrc.local`. The migration gate protects `~/.bashrc.local` from ever being modified.
3. Pre-migration configuration snapshots are taken automatically to `~/.local/state/omarchy/migration-backups/`.
4. If an upstream script modifies a file with user alterations, changes are written to `<filename>.omarchynew` (following Arch Linux `.pacnew` conventions), and a unified diff is logged to `migration-conflicts.log`.

#### Hardened Sysctl Stability Policy (`99-zz-omarchy-wsl-stability.conf`)
The migration gate guarantees that after every migration run, `/etc/sysctl.d/99-zz-omarchy-wsl-stability.conf` is re-asserted. Because it begins with `99-zz`, systemd-sysctl evaluates it **last**, definitively overriding `99-omarchy-sysctl.conf`:
```ini
# /etc/sysctl.d/99-zz-omarchy-wsl-stability.conf
vm.vfs_cache_pressure = 100
vm.swappiness = 10
vm.min_free_kbytes = 131072
vm.overcommit_memory = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
fs.file-max = 2097152
```

---

## 5. Attack Angle 4: CI/CD Release Pipeline & Distribution Infrastructure

### 5.1 Multi-Architecture Packaging Strategy

WSL supports both `x86_64` (AMD64) and `aarch64` (ARM64). Because `wslc.exe` is a Windows-only tool that cannot cross-compile, our GitHub Actions pipeline utilizes an OCI container workflow on Linux runners:

```
┌────────────────────────────────────────────────────────────────────────┐
│               GitHub Actions CI/CD Release Pipeline                    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
         ┌──────────────────────────┴──────────────────────────┐
         ▼                                                     ▼
┌─────────────────────────────────┐           ┌─────────────────────────────────┐
│     Matrix: x86_64 (amd64)      │           │      Matrix: arm64 (aarch64)    │
│     Runner: ubuntu-latest       │           │     Runner: ubuntu-24.04-arm    │
│                                 │           │                                 │
│ 1. Pull archlinux:latest        │           │ 1. Unpack ALARM rootfs (Alpine) │
│ 2. Install [omarchy] repo       │           │ 2. Build yay, mise, nvim from src
│ 3. Inject WSL configs & icons   │           │ 3. Inject WSL configs & icons   │
│ 4. Export -> Omarchy-x86_64.wsl │           │ 4. Export -> Omarchy-arm64.wsl  │
└────────────────┬────────────────┘           └────────────────┬────────────────┘
                 │                                             │
                 └──────────────────────┬──────────────────────┘
                                        ▼
                      ┌───────────────────────────────────┐
                      │    Release & Cryptographic Sign   │
                      │                                   │
                      │ • sha256sum -> SHA256SUMS         │
                      │ • Cosign keyless OIDC sign        │
                      │ • Publish GitHub Release (v*)     │
                      │ • Winget manifest validation      │
                      └───────────────────────────────────┘
```

### 5.2 Adversarial Validation Gates in CI

Before attaching any `.wsl` file to a release, the pipeline enforces automated verification:
1. **Archive Content Gate:** `tar -ztvf Omarchy-<arch>.wsl` confirms the presence of:
   - `/etc/wsl.conf` (permissions `0644`, `systemd=true`)
   - `/etc/wsl-distribution.conf` (default name `Omarchy`, defaultUid `1000`)
   - `/etc/oobe.sh` (permissions `0755`)
   - `/usr/lib/wsl/terminal-profile.json`
   - `/usr/lib/wsl/omarchy.ico` (multi-resolution icon generated via ImageMagick)
2. **Masked Unit Audit:** Confirms that `systemd-firstboot.service` and `systemd-resolved.service` are masked so boots do not hang at the init console.
3. **Keyless Sigstore Signing:** Checksums are signed using Sigstore Cosign via GitHub Actions OIDC identity (`id-token: write`), generating verifiable transparency-log proofs (`SHA256SUMS.bundle`) without managing long-lived private keys.

---

## 6. End-to-End Lifecycle State Machine

```
  [User executes irm | iex]
             │
             ▼
  ┌───────────────────────┐
  │ Pre-flight & Audits   │ ──(Failed)──► Abort with actionable guidance
  └──────────┬────────────┘
             │ (Passed)
             ▼
  ┌───────────────────────┐
  │ Distro Collision Gate │ ──(Exists)──► Prompt: In-place update | Side-by-side | Abort
  └──────────┬────────────┘
             │ (Unique Name)
             ▼
  ┌───────────────────────┐
  │ Download & Verify     │ ──(Hash Fail)──► Purge temp files & Abort
  │ SHA-256 Checksum      │
  └──────────┬────────────┘
             │ (Verified)
             ▼
  ┌───────────────────────┐
  │ Register WSL Distro   │
  │ (User Scope)          │
  └──────────┬────────────┘
             │
             ▼
  ┌───────────────────────┐
  │ Post-Install Health   │
  │ Boot Verification     │
  └──────────┬────────────┘
             │
             ▼
  ┌───────────────────────┐
  │ Normal Daily Usage    │
  └──────────┬────────────┘
             │
    [omarchy-wsl-update]
             │
             ▼
  ┌───────────────────────┐
  │ In-Place Update:      │
  │ • Pacman keyrings     │
  │ • pacman -Syu         │
  │ • Git fast-forward    │
  │ • Migration Gate      │
  │ • Sysctl stability    │
  └───────────────────────┘
```

---

## 7. Artifact Deliverables Summary

| File | Purpose | Location |
| :--- | :--- | :--- |
| `install.ps1` | Hardened, zero-admin, SHA-256 verified one-line installer | `install/install.ps1` |
| `omarchy-wsl-update` | Zero-data-loss in-place rolling update script | `bin/omarchy-wsl-update` |
| `migration-gate` | WSL virtualization shims & dotfile protection | `lib/omarchy-wsl-migration-gate` |
| `99-zz-stability.conf` | Hardened memory & sysctl stability configuration | `wsl/99-zz-omarchy-wsl-stability.conf` |
| `release.yml` | Dual-arch GitHub Actions CI/CD workflow | `.github/workflows/release.yml` |
| `Omacom.OmarchyWSL.yaml`| Windows Package Manager (Winget) manifest | `winget/Omacom.OmarchyWSL.yaml` |

---
*Signed and verified by Hermes Architecture Engine.*
