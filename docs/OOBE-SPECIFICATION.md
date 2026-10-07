# Omarchy-WSL: Dynamic First-Boot OOBE & User Provisioning Specification

**Document Version:** 1.0.0  
**Target Systems:** Windows Subsystem for Linux (WSL 2 / WSL 3.0.1)  
**Supported Architectures:** ARM64 (Qualcomm Snapdragon X Elite / Oryon) and x86_64 (Intel / AMD)  
**Status:** Approved & Verified  

---

## 1. Executive Summary & Problem Statement

Upstream distribution bootstrap implementations for WSL have historically suffered from rigid user hardcoding:
1. **Craig Loewen's Upstream Implementations:** Hardcoded the static user `omarchy` across installation manifests, causing directory mismatches for users with different host account names and breaking single-tenant toolchains.
2. **Naive Custom Scripts:** Hardcoded developer-specific identities (such as `aqua`), rendering the distribution non-neutral and breaking out-of-the-box developer experiences for general Windows users.
3. **Microsoft's Documentation Sample OOBE:** Relied on Debian-specific utilities (`adduser --gecos`, Debian group lists `adm,cdrom,sudo,dip,plugdev`), assumed interactive standard input, and lacked error recovery for UID 1000 collisions on stock rootfs images (such as Arch Linux ARM's default `alarm` account).

**Omarchy-WSL** resolves these architectural flaws with a completely neutral, dynamic, first-boot Out-Of-Box Experience (OOBE) engine. It delivers zero user hardcoding, multi-vector host username discovery, POSIX-strict sanitization, atomic system configuration, and seamless transition from root to the primary UID 1000 developer account.

---

## 2. Adversarial Threat Model & Attack Angle Analysis

### Attack Angle 1: Host `%USERNAME%` Detection Across WSL Interop
* **Attack Scenario A (Path Isolation):** Distribution ships with `/etc/wsl.conf` specifying `appendWindowsPath = false` to keep Linux `$PATH` clean. Standard `cmd.exe` or `powershell.exe` calls fail with `command not found`.
  * **Mitigation:** Probes explicit System32 paths (`/mnt/c/Windows/System32/cmd.exe`, `/c/Windows/System32/cmd.exe`) and dynamically inspects `/proc/mounts` for all 9p / DrvFs mountpoints to locate the active Windows directory regardless of custom automount configurations.
* **Attack Scenario B (Interop Disabled / Blocked):** WSL interop is disabled globally in `.wslconfig` (`[wsl2] interop=false`) or `binfmt_misc` is unmounted. Direct execution of `.exe` binaries yields `ENOEXEC` (Exec format error).
  * **Mitigation:** Every interop command is guarded by `timeout 3` inside an isolated subshell with stderr discarded. When execution fails, the engine falls back to reading the DrvFs user directory (`<mount>/Users/`) and filtering out system accounts (`Default`, `Public`, `Administrator`), before finally falling back to the deterministic default (`omarchy`).
* **Attack Scenario C (CRLF & Formatting Artifacts):** `cmd.exe /c "echo %USERNAME%"` emits `%USERNAME%\r\n`. Naive extraction leaves trailing `\r`, corrupting usernames and file paths.
  * **Mitigation:** Explicitly strips `\r\n` and trims surrounding whitespace.

### Attack Angle 2: POSIX Username Sanitization & Normalization
* **Attack Scenario:** Windows usernames commonly contain spaces (`John Doe`), uppercase (`AliceSmith`), dots (`john.doe`), symbols (`user@work!`), leading numbers (`123agent`), diacritics (`François`, `Müller`), or non-ASCII scripts (CJK `张伟`, Cyrillic `Иван`, emoji `🚀`).
* **Linux POSIX Requirement:** Standard POSIX usernames must match `^[a-z_][a-z0-9_-]{0,31}$` and cannot begin with a digit or hyphen.
* **Sanitization Pipeline:**
  1. Strip CRLF and whitespace padding.
  2. Lowercase transformation (`tr '[:upper:]' '[:lower:]'`).
  3. Safe ASCII transliteration via `iconv -f UTF-8 -t ASCII//TRANSLIT` (e.g. `François` $\rightarrow$ `francois`, `Müller` $\rightarrow$ `m_uller`).
  4. Replace illegal characters with underscores (`[^a-z0-9_-]` $\rightarrow$ `_`).
  5. Collapse contiguous underscores/hyphens (`[_-]+` $\rightarrow$ `_`).
  6. Fix invalid initial characters: prepend `u_` if starting with a digit (`123agent` $\rightarrow$ `u_123agent`) or prefix with `_` if starting with a hyphen.
  7. Strip trailing underscores.
  8. Truncate to 31 characters (`POSIX UT_NAMESIZE - 1`).
  9. Regex validation: if result is empty or non-compliant (e.g. untransliterable CJK/emoji), safely fall back to `omarchy`.

### Attack Angle 3: Non-Interactive (Headless) & Automated Invocations
* **Attack Scenario:** Automated tooling (`wsl.exe -d Omarchy --exec echo ready`, CI runners, Packer, or `install.ps1` health check `wsl -d Omarchy -- whoami`) executes non-interactively. An interactive `read -p` prompt encounters closed stdin / `/dev/null`, returns exit code 1 on EOF, trips `set -e`, and crashes OOBE. Because `wsl-distribution.conf` aborts the shell on non-zero exit, the distribution fails to install.
* **Mitigation:** Checks `[[ ! -t 0 || ! -t 1 || "${CI:-}" == "true" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]`. In headless mode, OOBE runs 100% unattended: uses the detected & sanitized username, provisions passwordless sudo, enables systemd lingering, updates `/etc/wsl.conf`, and exits 0 immediately.

### Attack Angle 4: Collision Detection with `/etc/passwd` & System UIDs
* **Attack Scenario A (System Account Collision):** The Windows username is `daemon`, `root`, `admin`, `bin`, `sys`, `sshd`, or `dbus`. Overwriting or modifying system accounts corrupts system services.
  * **Mitigation:** Queries `id -u "$candidate"`. If UID $< 1000$, the account is identified as a reserved system account. In interactive mode, the user is warned and prompted to enter an alternative username. In headless mode, OOBE prefixes the name (`u_$candidate`) to guarantee safety.
* **Attack Scenario B (UID 1000 Collision on Stock Rootfs):** Arch Linux ARM (ALARM) ships with default user `alarm` on UID 1000. Cloned or template rootfs images may ship with `aqua` or `omarchy`. Blindly running `useradd -u 1000` fails with `UID 1000 is not unique`. Allocating UID 1001 causes WSL to launch the wrong user because `wsl-distribution.conf` specifies `defaultUid = 1000`.
  * **Mitigation:** Reconciler detects existing UID 1000 account. It terminates any lingering processes (`pkill -u 1000`), cleanly renames the user and group via `usermod -l` and `groupmod -n`, migrates the home directory via `usermod -d /home/$target -m`, and resets permissions. If rename fails, it removes the stock template user and recreates UID 1000 cleanly.

### Attack Angle 5: Sudoers Configuration & Administrative Safety
* **Attack Scenario:** Syntactic errors or permission violations in `/etc/sudoers.d/` cause `sudo` to fail globally, locking out the user and administrator. Mode `0644` or world-writable permissions cause sudo to reject the file.
* **Mitigation:**
  - Writes rule to temporary file (`.tmp_10_${target_user}.$$`).
  - Sets mode `0440` owned by `root:root`.
  - Runs `visudo -cqf "$tmp_file"` to validate grammar prior to moving into place.
  - Ensures `@includedir /etc/sudoers.d` is active in `/etc/sudoers`.
  - Configures passwordless sudo (`NOPASSWD: ALL`) by default for seamless developer ergonomics, while allowing interactive password enforcement if requested.

### Attack Angle 6: Offline Systemd Lingering (`loginctl enable-linger`)
* **Attack Scenario:** During container build phases, chroot initialization, or early boot before D-Bus and `systemd-logind` are active, `loginctl enable-linger` fails with `Failed to connect to bus`. If unhandled under `set -e`, OOBE crashes.
* **Mitigation:** Directly creates `/var/lib/systemd/linger/$target_user` with mode `0644` and owner `root:root`. Systemd-logind natively honors this file on disk at startup. In addition, if systemd is active as PID 1, it invokes `loginctl enable-linger "$target_user"` as a secondary confirmation.

### Attack Angle 7: Atomic `/etc/wsl.conf` Updating
* **Attack Scenario:** Abrupt shutdown or process termination during file write produces a zero-length or corrupted `/etc/wsl.conf`. Blindly appending `[user]\ndefault = ...` creates duplicate INI sections.
* **Mitigation:** Pure AWK parser processes existing `/etc/wsl.conf`. If `[user]` section exists, it replaces `default = ...` within the section; if `[user]` is missing, it creates the section. All other sections, keys, and comments are preserved. Output is written to a temporary file in the same directory, flushed with `sync`, and atomically moved over `/etc/wsl.conf`.

### Attack Angle 8: Transition from Root to UID 1000 User Across Install Vectors
* **Native Store / `.wsl` Bundle Vector:** Handled by `/etc/wsl-distribution.conf` `[oobe] command = /usr/lib/omarchy-wsl/oobe.sh` and `defaultUid = 1000`. WSL runs OOBE as root on first launch, succeeds, and launches UID 1000.
* **Manual `wsl --import` Tarball Vector:** `wsl --import` bypasses `wsl-distribution.conf`. Users drop into root shells on first launch.
  * **Mitigation:** Drop-in `/etc/profile.d/00-omarchy-firstboot.sh` triggers for root when `/var/lib/omarchy/oobe_completed` is missing. It executes `oobe.sh`, provisions the user, and immediately executes `exec runuser -u "$PROVISIONED_USER" -- /bin/bash -l` to seamlessly transition the interactive session into the new user without requiring manual login. Subsequent launches use `/etc/wsl.conf` `[user] default = <user>`.

---

## 3. Specifications of Delivered Artifacts

### 3.1 Distribution Configuration: `/etc/wsl-distribution.conf`
Located in repository at `wsl/wsl-distribution.conf`:
```ini
[oobe]
command = /usr/lib/omarchy-wsl/oobe.sh
defaultUid = 1000
defaultName = Omarchy

[shortcut]
enabled = true
icon = /usr/share/omarchy/assets/omarchy.ico

[windowsterminal]
enabled = true
ProfileTemplate = /usr/share/omarchy/assets/terminal-profile.json
```

### 3.2 Base Virtualization Configuration: `/etc/wsl.conf`
Located in repository at `wsl/wsl.conf`:
```ini
[boot]
systemd = true

[automount]
enabled = true
root = /mnt/
options = "metadata,uid=1000,gid=1000,umask=022,fmask=011,case=off"
mountFsTab = true

[network]
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = false
```

### 3.3 Dynamic OOBE Provisioning Engine: `/usr/lib/omarchy-wsl/oobe.sh`
Located in repository at `wsl/oobe.sh`:
* Fully portable, POSIX-compatible Bash script passing `shellcheck` with zero warnings.
* Provides modular functions:
  - `detect_windows_username()`: 8-stage detection hierarchy.
  - `sanitize_username()`: POSIX username sanitization.
  - `resolve_name_collision()`: Reserved system UID reservation guard.
  - `provision_user_account()`: UID 1000 reconciler.
  - `assign_secondary_groups()`: Dynamic existence probing for `wheel,docker,audio,video,render,kvm,storage,input`.
  - `configure_sudoers()`: Visudo-verified drop-in in `/etc/sudoers.d/10-$user`.
  - `configure_systemd_linger()`: Direct filesystem and D-Bus lingering.
  - `update_wsl_conf()`: Atomic INI updater.
  - `scaffold_home_directory()`: Single-root `~/hermes/{workspace,worktrees,scratch}` scaffolding.
  - `setup_user_environment()`: Neovim, Tokyo Night theming, and mise toolchain setup.
  - `write_sentinel()`: Idempotency sentinel in `/var/lib/omarchy/oobe_completed`.

### 3.4 First-Boot Profile Hook: `/etc/profile.d/00-omarchy-firstboot.sh`
Located in repository at `wsl/00-omarchy-firstboot.sh`:
* Guarantees fallback OOBE execution and seamless `exec runuser` session transition for manual `wsl --import` workflows.

### 3.5 Windows Terminal Profile Template: `terminal-profile.json`
Located in repository at `wsl/terminal-profile.json`:
* Configures Tokyo Night theme, Cascadia Code font, and Acrylic blur integration for the Windows host terminal.

---

## 4. Verification & Proof Evidence

### 4.1 Adversarial Bash Test Suite (`tests/test_oobe_adversarial.sh`)
* **Execution:** Ran 34 adversarial test cases in isolated sandbox.
* **Results:**
  ```text
  ========================================================================
   Omarchy WSL: Running Adversarial OOBE Proof Suite
  ========================================================================
  --- Suite 1: Adversarial Username Sanitization Engine ---
    [PASS] Standard lowercase
    [PASS] Space in username ('John Doe')
    [PASS] Multiple spaces and dots
    [PASS] Special symbols ('user@host#1!')
    [PASS] Leading digit ('123agent' -> 'u_123agent')
    [PASS] Leading hyphen ('-baduser' -> '_baduser')
    [PASS] Unicode Latin diacritics ('François')
    [PASS] Unicode German umlaut ('Müller')
    [PASS] Non-ASCII CJK fallback ('张伟')
    [PASS] Non-ASCII Cyrillic fallback ('Иван')
    [PASS] Pure emoji fallback ('🚀')
    [PASS] Empty string fallback
    [PASS] Overlong username truncated to 31 chars

  --- Suite 2: Host %USERNAME% Detection Vector Fallbacks ---
    [PASS] Explicit OMARCHY_USER env override
    [PASS] Config file /etc/omarchy-user.conf override
    [PASS] WSLENV forwarded USERNAME
    [PASS] DrvFs Users folder inspection

  --- Suite 3: Atomic /etc/wsl.conf INI Updater ---
    [PASS] New wsl.conf contains [user]
    [PASS] New wsl.conf contains default = alice
    [PASS] New wsl.conf retains systemd = true
    [PASS] Appends [user] when missing
    [PASS] Sets default = bob_builder
    [PASS] Preserves appendWindowsPath = false
    [PASS] Updates existing default to charlie
    [PASS] Preserves following [network] section
    [PASS] Old user default was cleanly purged

  --- Suite 4: Sudoers Drop-in Safety & Validation ---
    [PASS] visudo validates drop-in rule
    [PASS] Sudoers contains NOPASSWD rule for %wheel
    [PASS] Sudoers contains NOPASSWD rule for user

  --- Suite 5: Offline Systemd Lingering Engine ---
    [PASS] Linger marker file created at /tmp/.../linger/testdev

  --- Suite 6: System Account Collision Detection ---
    [PASS] System user 'root' converted to 'u_root'
    [PASS] System user 'daemon' converted to 'u_daemon'
    [PASS] Regular user 'john_doe' kept as 'john_doe'

  --- Suite 7: Profile Hook (/etc/profile.d/00-omarchy-firstboot.sh) ---
    [PASS] First-boot profile hook syntax validation

  ========================================================================
   Test Results: 34 Passed, 0 Failed
  ========================================================================
  ```

### 4.2 Python Property-Based Test Suite (`tests/unit/test_oobe_adversarial.py`)
* **Execution:** Ran unit test cases for distribution manifests, regex validation, and INI mutations.
* **Results:**
  ```text
  Ran 9 tests in 0.510s
  OK
  ```

### 4.3 Static Analysis & Linter Verification
* `shellcheck wsl/oobe.sh`: Clean (0 warnings, 0 errors).
* `shellcheck wsl/00-omarchy-firstboot.sh`: Clean (0 warnings, 0 errors).
* `bash -n`: Valid syntax across all scripts.
