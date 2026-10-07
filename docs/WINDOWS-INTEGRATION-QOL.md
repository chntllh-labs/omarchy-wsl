# Omarchy-WSL: Windows 11 Integration & Quality-of-Life Architecture

**Distribution Engine:** Omarchy-WSL (Arch Linux for WSL2, WSL 2.5 – 3.0.x)
**Host:** Windows 11 22H2+ (x64 and ARM64 / Snapdragon X, X2)
**Scope:** 10 adversarial research vectors covering Explorer, clipboard, SSH/GPG agents, Git credentials, launchers, toasts, audio, containers, file watching and power.
**Verification:** `bash tests/test_windows_integration.sh` (192 gates, simulated Windows host + live end-to-end paths)

---

## 0. Executive Summary

| # | Domain | Deliverable | Installed as | Default state |
|:-:|:--|:--|:--|:--|
| 1 | Explorer & directory ergonomics | `bin/omarchy-sync-dirs`, `tools/register-explorer-context-menu.{ps1,reg}`, DrvFs guard | `/usr/bin`, Windows-side scripts, `/etc/profile.d/40-…` | Guard on; links/menu opt-in |
| 2 | Clipboard, OSC 52, images | `bin/omarchy-clip`, Neovim + tmux snippets | `/usr/bin`, `/usr/share/omarchy/{nvim,tmux}` | Available |
| 3 | SSH agent & GPG smartcard | `wsl/bin/omarchy-ssh-agent-bridge` + user unit | `/usr/lib/omarchy-wsl/bin`, `systemd --user` | Opt-in (`enable`) |
| 4 | Git Credential Manager sharing | `wsl/bin/omarchy-git-credential-bridge` | `/usr/lib/omarchy-wsl/bin` | Opt-in (`install`) |
| 5 | URL / file / editor launcher | `bin/omarchy-open`, `$BROWSER` export | `/usr/bin`, `/etc/profile.d/20-omarchy-browser.sh` | On (`BROWSER` if unset) |
| 6 | Windows toast notifications | `bin/omarchy-notify`, Tokyo Night PNG icons | `/usr/bin`, `/usr/share/omarchy/notify` | Available; `omarchy-build --notify` |
| 7 | WSLg audio & microphone | PulseAudio client drop-in, environment.d, user tmpfiles, ALSA route | `/etc/pulse/client.conf.d/wslg.conf` … | On |
| 8 | Docker / Podman engine bridge | `bin/omarchy-docker-bridge` | `/usr/bin`, `/etc/profile.d/50-omarchy-docker.sh` | Opt-in (`use`) |
| 9 | Windows edits → Linux hot-reload | `bin/omarchy-watch-bridge` | `/usr/bin` | On demand |
| 10 | Battery / thermal governor | `bin/omarchy-power-governor`, wired into `omarchy-build` | `/usr/bin` | On (computed `-j` only) |

All tools share one hardened interop layer, `lib/omarchy-wsl-interop.sh` → `/usr/lib/omarchy-wsl/interop.sh`.

### 0.1 Where the brief's assumptions did not survive research

| Brief assumption | Finding | What we did instead |
|:--|:--|:--|
| Route `/var/run/docker.sock` to the chosen engine | Docker Desktop's integration owns that path; clobbering it breaks Desktop, and `DOCKER_HOST` beats `docker context` | Stable per-user socket + opt-in `DOCKER_HOST`; `/run/docker.sock` only via explicit `install-system`, never over a live socket |
| "Bidirectional clipboard sync daemon" | WSLg already syncs Wayland↔Windows over RDP, but with open bugs (CRLF, 64 KiB cap on X11, random desync, focus stealing) — a second daemon would add another racing owner | A stateless router that picks the most reliable backend per call |
| OSC 52 "works natively" both ways | Windows Terminal implements OSC 52 **write only**; reads were rejected as an exfiltration hole (microsoft/terminal#5823) | Copy via OSC 52; paste is refused explicitly instead of hanging |
| Sharing GitHub credentials avoids `gh auth login` via token import | `gh auth login --with-token` rejects GCM tokens (scopes `repo gist workflow`, lacks `read:org`) | `exec-gh`: per-process `GH_TOKEN` borrowed from GCM (not scope-validated, never persisted) |
| OSC 9 / OSC 777 produce Windows toasts | WT has OSC 9;4 progress since 1.6; OSC 777 only in WT Preview 1.26 behind `compatibility.allowOSC777`; plain OSC 9 text is not implemented | WinRT toast via PowerShell 5.1 is primary; OSC 777/9 + BEL is the fallback; OSC 9;4 drives the taskbar progress ring |
| Tune WSLg audio latency in `client.conf` | `client.conf` has no latency keys; WSLg crackling is an **unfixed server-side RDPSink underrun** (microsoft/wslg#1429) | Pin the server for systemd services, restore hidden sockets, client buffer via `PULSE_LATENCY_MSEC`; documented honestly as mitigation, not a fix |
| Ship a `binfmt.d/WSLInterop.conf` | WSL ≥ 2.5.7 regenerates/protects the entry (`[boot] protectBinfmt`, PR #41780); a shipped file makes `systemd-binfmt` fail on the read-only mount | Detect & diagnose instead (`omw_require_interop`, `doctor`); manual remedy documented below |
| npiperelay must sit on `/mnt/c` | Not strictly required with modern interop (albertony fork), but much faster there; and there are **no ARM64 builds** (x64 runs under Prism) | Discovery prefers Windows-drive locations; `doctor` warns when it lives on ext4 |

---

## 1. Cross-Cutting Architecture: The Interop Layer

Every tool sources `interop.sh`. Its rules are the security model of this whole document.

```
 Linux tool ──► interop.sh ──┬─► absolute DrvFs path  (/mnt/c/Windows/System32/clip.exe)
                             ├─► powershell.exe -EncodedCommand <base64(UTF-16LE)>
                             │       user data: base64 literals or stdin, never script text
                             ├─► cmd.exe /d /c "echo %VAR%"   (VAR ∈ ^[A-Za-z_][A-Za-z0-9_]*$, cached 24 h)
                             └─► timeout --kill-after=2 $OMW_TIMEOUT  (every call)
```

1. **No Windows `%PATH%`.** `wsl.conf` keeps `appendWindowsPath = false`; binaries are resolved by absolute path, discovering the Windows directory on any drive and honouring a custom `[automount] root`. This removes the PATH-ordering hijack class (a `git.exe` shadowing Linux `git`) and the 100+ ms per-lookup cost of walking DrvFs directories.
2. **No shell metacharacter surface.** `cmd.exe` is used for one fixed probe only. PowerShell runs with `-EncodedCommand`; its alphabet (`A–Z a–z 0–9 + / =`) cannot terminate a quoted argument. User strings enter as `[Convert]::FromBase64String('…')`. This also defeats a lesser-known PowerShell quirk: U+2018/U+2019 curly quotes are string delimiters (PowerShell language spec ch. 2), so naive `'` doubling is insufficient.
3. **Bounded and isolated.** Every Windows call has a timeout. `powershell.exe` gets `</dev/null` unless the caller passes `--stdin`: an inherited terminal lets it swallow keystrokes; an inherited idle pipe hangs it (the test suite caught exactly this).
4. **UTF-8 end to end.** A BOM-less UTF-8 preamble is set on both console directions; stray BOMs and CRs are stripped.
5. **Private runtime state.** `$XDG_RUNTIME_DIR/omarchy` (fallback `/tmp/omarchy-runtime-$UID`) is created `0700` and rejected if owned by another user.
6. **Shared relay helpers.** npiperelay discovery and the socat wrapper writer (socat's `EXEC:` splits on spaces and cannot quote `C:\Users\Jane Doe\…`) live here, used by Domains 3 and 8.
7. **Test seams** (`OMW_FORCE_WSL`, `OMW_FORCE_INTEROP`, `OMW_MOUNT_ROOT`, `OMW_MOUNTINFO`, `OMW_POWERSHELL`, `OMW_PS_TRACE`) let the suite run the real code against a fake Windows host.

**Interop health.** If executing `.exe` fails with `Exec format error`, the `WSLInterop` binfmt entry is gone. On current WSL run `wsl --update` (≥ 2.5.7 regenerates it). On older builds, as root: `echo ':WSLInterop:M::MZ::/init:FP' > /proc/sys/fs/binfmt_misc/register`.

---

## Domain 1: Common Directory Ergonomics & Explorer Shell Integration

### Findings
- **Known Folders move.** OneDrive Known Folder Move, Group Policy and users relocate Desktop/Documents/Downloads; `C:\Users\<name>\Downloads` is a guess. Raymond Chen explicitly warns against reading `Shell Folders`/`User Shell Folders` (values are `REG_EXPAND_SZ` and the key is a compatibility shim). `[Environment]::GetFolderPath()` honours redirection; Downloads has no `SpecialFolder` value, so it is resolved through the `shell:Downloads` namespace (`SHGetKnownFolderPath` underneath).
- **OneDrive placeholders hydrate on read** (`RECALL_ON_DATA_ACCESS`). A Linux `rg`/`cat`/`du -a` across a redirected folder downloads it.
- **Symlinks are safe for traversal tools:** `fd`, `rg` and `find` do not follow symlinks by default, so `~/win/*` does not leak into project-wide searches.
- **Context menus.** Classic verbs live under `HKCU\Software\Classes\{Directory\Background,Directory,Drive}\shell`. A bare `"%V"` breaks on drive roots: `wt -d "C:\"` makes `\"` an escaped quote (microsoft/terminal#4571, still open). The `"%V."` idiom yields `C:\.` for roots, and Win32 path normalisation strips the trailing dot elsewhere. Windows 11 places classic verbs under **Show more options**; top-level placement needs an `IExplorerCommand` in a signed sparse package.
- **Quick Access** pinning via `Shell.Application … InvokeVerb('pintohome')` *toggles*: it unpins an already-pinned folder.

### Adversarial analysis
| Attack / failure | Consequence | Mitigation |
|:--|:--|:--|
| Re-running the link tool over a real `~/win/Documents` | Data loss | Never replace non-symlinks; only re-point symlinks that already target DrvFs; `--force` needed for foreign symlinks |
| Interrupted link swap | Missing link | `ln -s tmp && mv -fT tmp dest` (atomic rename) |
| `npm install` / `cargo build` in `/mnt/c` | 9P round-trip per `stat()`, watchers blind | Interactive DrvFs guard + `omarchy-build` refusal |
| Symlink escapes (`~/work → /mnt/c/work`) | Guard bypass via logical `$PWD` | Guard resolves the physical cwd (`pwd -P`) |
| Distro name injected into registry command | Arbitrary command in Explorer verb | `ValidatePattern` on `-Distro`/`-TerminalProfile`/`-Label` |
| `pintohome` toggle | Second install unpins | Enumerate Quick Access (`shell:::{679f85cb-…}`) first |

### Engineering
**`omarchy-sync-dirs`** — one PowerShell call resolves all Known Folders, links them into `~/win/<Name>`, warns about OneDrive hydration, skips network shares, writes `~/win/.omarchy-boundary`.
```bash
omarchy-sync-dirs                         # Downloads Desktop Documents
omarchy-sync-dirs --dirs "Downloads Pictures Home"
omarchy-sync-dirs --status | --dry-run | --remove
omarchy-sync-dirs --pin-quick-access      # pins \\wsl.localhost\Omarchy\home\<you>
```
**DrvFs guard** (`/usr/lib/omarchy-wsl/drvfs-guard.sh`, loaded for interactive bash/zsh): wraps `cargo make cmake ninja meson npm npx pnpm yarn bun deno go gradle mvn dotnet omarchy-build` (blocked) and `git` (warned) only when the physical cwd is on a Windows drive. It never shadows user aliases/functions (zsh-safe detection: `declare -F` declares a *float* in zsh) and is inert in scripts. `OMARCHY_DRVFS_GUARD=block|warn|off`.

**Explorer verb** (Windows side, no admin):
```powershell
powershell -ExecutionPolicy Bypass -File tools\register-explorer-context-menu.ps1 -PinQuickAccess
powershell -ExecutionPolicy Bypass -File tools\register-explorer-context-menu.ps1 -Uninstall
# or double-click tools\register-explorer-context-menu.reg / unregister-…reg
```
Prefers `wt.exe -w 0 new-tab -p "Omarchy" -d "%V."` via the absolute App Execution Alias path, falling back to `wsl.exe -d Omarchy --cd "%V."` (`--cd` accepts Windows and `\\wsl.localhost` paths). Icon copied from the distro to `%LOCALAPPDATA%\Omarchy`. `.reg` files are forced to CRLF via `.gitattributes`.

---

## Domain 2: Cross-OS Clipboard, OSC 52 & Rich Media

### Findings
- **WSLg** syncs text both ways through Weston's RDP backend; images partially. Open issues: CRLF injection (wslg#1326), Windows→X11 64 KiB cap (#743), images reaching Wayland as `image/bmp` only (#833), random desync after hours/days (#1202), background `wl-paste` stealing focus for lack of a data-control protocol (#1512), msrdc clipboard lock breaking Win+Shift+S (#1499).
- **`clip.exe`** decodes stdin in the OEM/ANSI codepage → mojibake for UTF-8. Feeding UTF-16LE with a BOM is the widely used fix (community-verified; Microsoft does not document clip's encoding detection).
- **PowerShell:** `Get-Clipboard -Format Image` exists only in 5.1; both 5.1 and pwsh 7 default to STA on Windows, so `System.Windows.Forms.Clipboard` works in either. **win32yank** (`-i --crlf`, `-o --lf`) is the fastest path but dormant upstream (last commit 2024-03).
- **OSC 52:** Windows Terminal writes only (PR #5823). tmux's `set-clipboard` default is `external`; `on` also forwards application OSC 52; `allow-passthrough` gates DCS. Neovim 0.10 auto-enabled OSC 52 only over SSH; 0.11 detects terminal support in any TUI when no other provider exists.
- **img-clip.nvim** on WSL uses `powershell.exe … Clipboard::GetImage()` even under WSLg.

### Engineering — `omarchy-clip`
| Session | copy | paste |
|:--|:--|:--|
| WSL + interop, win32yank installed | win32yank `-i` (~15 ms) | win32yank `-o --lf` |
| WSL + interop | `clip.exe` ← UTF-16LE+BOM | PowerShell `Clipboard::GetText()` (CR stripped) |
| WSL + interop, `-t image/png` | PowerShell `DataObject` with both bitmap **and lossless `"PNG"` format** (data via stdin) | `"PNG"` format → copied image file (Explorer) → `CF_DIB`, emitted as PNG |
| SSH, no interop | OSC 52 (tmux: `load-buffer -w`, else DCS-wrapped) | refused with an explanation |
| WSLg only | `wl-copy` | `wl-paste` under `timeout 3` |

OSC 52 payloads above `OMARCHY_OSC52_MAX` (100 000 base64 bytes) are refused rather than silently truncated.
```bash
echo "héllo ✓" | omarchy-clip copy
omarchy-clip paste -t image/png > shot.png     # Snipping Tool → Neovim/Markdown
omarchy-clip backend copy                      # explain routing
```
- **Neovim:** `dofile("/usr/share/omarchy/nvim/omarchy-clipboard.lua")` — local sessions use `omarchy-clip`; SSH sessions use the built-in OSC 52 copier with paste from the unnamed register (an OSC 52 query would block until timeout on WT). Includes an img-clip.nvim / image-paste keymap recipe.
- **tmux:** `source-file /usr/share/omarchy/tmux/omarchy-clipboard.conf` — `set-clipboard on`, `allow-passthrough on`, `copy-command 'omarchy-clip copy'`, vi-mode yank bindings, `prefix C-v` pastes the Windows clipboard.

---

## Domain 3: SSH Agent & GPG Smartcard Forwarding

### Findings
- **WSL2 has no native named-pipe or AF_UNIX bridge.** AF_UNIX interop is WSL1-only; microsoft/WSL#5961 remains open and no WSL release through 3.0.2 adds one. A relay process is mandatory.
- **npiperelay:** `jstarks/npiperelay` is dormant (v0.1.0, 2020). The maintained fork is **`albertony/npiperelay`** (v1.12.x, `winget install albertony.npiperelay`), x86/x64 builds only. Flags: `-ei` exit on stdin EOF, `-ep` exit on pipe EOF, `-s` send 0-byte message on EOF, `-p` poll, `-a` Assuan (GnuPG) mode.
- **Who owns `\\.\pipe\openssh-ssh-agent`:** Windows OpenSSH agent, **1Password** and **Bitwarden** (both require *disabling* the Windows "OpenSSH Authentication Agent" service). **KeePassXC** is not an agent; in OpenSSH mode it loads keys into the Windows service, which must be *enabled*. **Pageant** (PuTTY ≥ 0.75) listens on `\\.\pipe\pageant.<user>.<hash>` and writes it with `pageant --openssh-config FILE`.
- 1Password's official WSL guidance is `core.sshCommand ssh.exe`; its WSL integration lists ARM devices as unsupported — the relay approach still works there through x64 emulation.
- **Gpg4win 5.x** (GnuPG 2.5) keeps sockets in `%LOCALAPPDATA%\gnupg` (since GnuPG 2.3.2). Windows libassuan emulates sockets as localhost TCP with a port+nonce file, hence `npiperelay -a`.

### Adversarial analysis
| Risk | Mitigation |
|:--|:--|
| Clobbering an `ssh -A` forwarded agent or gcr agent on the same path | `prepare_socket` probes with `ssh-add -l`; a live foreign agent → refuse. profile.d never overrides a live `SSH_AUTH_SOCK` |
| Other local users reaching the agent | socket `umask=177` → `0600`, runtime dir `0700` |
| Profile paths with spaces breaking socat `EXEC:` | Generated `%q`-quoted wrapper in the runtime dir |
| Pipe-name injection into the wrapper | `^[A-Za-z0-9._@{}-]+$` |
| Private keys copied into WSL | Never: all signing happens in the Windows vault (Windows Hello / 1Password approval still prompts) |
| Local `gpg-agent` stealing the bridged socket | Kills it and warns unless `no-autostart` is set in `gpg.conf` |

### Engineering — `omarchy-ssh-agent-bridge`
```
ssh ─► $XDG_RUNTIME_DIR/ssh-agent.sock ─► socat (fork) ─► npiperelay.exe -ei -s ─► \\.\pipe\openssh-ssh-agent
```
```bash
omarchy-ssh-agent-bridge doctor          # npiperelay, socat, pipes, agent service, 1Password/Bitwarden/KeePassXC
omarchy-ssh-agent-bridge start           # idempotent, flock-guarded
omarchy-ssh-agent-bridge enable          # systemd --user unit, or profile.d autostart
omarchy-ssh-agent-bridge start --pageant # pipe read from %USERPROFILE%\.ssh\pageant.conf
omarchy-ssh-agent-bridge gpg-start       # Gpg4win agent → $(gpgconf --list-dirs agent-socket)
```
The test suite proves the chain end to end: a real `ssh-agent` stands in for the Windows vault, and `ssh-keygen -Y sign` succeeds through the bridge *after the private key file is deleted*.

---

## Domain 4: Git Credential Manager & GitHub Authentication Sharing

### Findings
- GCM's documented WSL setup points `credential.helper` at the Windows `git-credential-manager.exe`, plus `credential.https://dev.azure.com.useHttpPath true` for Azure Repos.
- **The executable moves:** x64 Git for Windows **≥ 2.56 → `ucrt64/bin`**, ≤ 2.55 → `mingw64/bin`, ARM64 → `clangarm64/bin`, standalone → `Program Files\Git Credential Manager`, user installs → `%LOCALAPPDATA%\Programs\Git Credential Manager`. Standalone installs want `GIT_EXEC_PATH` shared through `WSLENV` (`/wp`).
- GCM writes LF (its stream writers set `NewLine = LineFeed`); CR stripping is defensive only.
- **gh:** `gh auth git-credential` answers only `get` for https; `store`/`erase` are no-ops. `gh auth login --with-token` enforces `repo` + `read:org`, so GCM's GitHub token (`repo gist workflow`) is rejected; `GH_TOKEN` is not scope-validated.

### Engineering — `omarchy-git-credential-bridge`
A real git credential helper that resolves GCM per call (cached 24 h), then falls back to `gh`, then answers nothing so git continues to its next helper/prompt.
- `GIT_TERMINAL_PROMPT=0` → `GCM_INTERACTIVE=never` via `WSLENV`, so agents/CI never block on a Windows OAuth dialog.
- Requests are validated as `key=value` lines (64 KiB cap) before reaching Windows; `store`/`erase` are forwarded so a revoked token is purged from the Windows vault; unknown actions are ignored per gitcredentials(7); 300 s timeout for browser OAuth.
```bash
omarchy-git-credential-bridge install     # backs up existing helpers; '' resets /etc/gitconfig helpers
omarchy-git-credential-bridge status
omarchy-git-credential-bridge exec-gh -- pr list    # gh without `gh auth login`
alias gh='omarchy-git-credential-bridge exec-gh --' # optional
omarchy-git-credential-bridge uninstall   # restores the saved helpers
```

---

## Domain 5: Windows Interop Utilities & Launcher Suite

### Findings
- **wslu is archived and discontinued** (last release v4.1.3, 2024). `wslview` builds `powershell.exe -Command "Start "<url>""` from `$*` inside double quotes, where PowerShell evaluates `$()` — a command-injection shape (our reading of the source; no CVE is assigned to wslu, though CVE-2026-54699 hit a Warp fallback path around it). Every call pays PowerShell start-up.
- `rundll32 url.dll,FileProtocolHandler` hands its argument to the registered protocol handler with **no filtering** (LOLBAS) — safe only behind a scheme allowlist that blocks `ms-msdt:` (CVE-2022-30190 "Follina"), `search-ms:`, `ms-officecmd:` and friends.
- `explorer.exe` exits 1 even on success and treats `,` and `=` as field separators. `cmd.exe` refuses UNC working directories.
- VS Code's Windows-side `bin/code` script detects `WSL_DISTRO_NAME` and hands off to Remote-WSL; `code --remote wsl+<distro> <path>` is supported. Cursor's CLI lives under `AppData\Local\Programs\cursor\resources\app\bin` (community-sourced).

### Engineering — `omarchy-open`
| Input | Path taken |
|:--|:--|
| `http(s)://`, `mailto:` | `rundll32.exe url.dll,FileProtocolHandler <url>` — single argv element, `" < > ^ | \` space` percent-encoded, control chars and >8 KiB refused (~40 ms, no shell) |
| other schemes | refused unless `--allow-scheme S` / `OMARCHY_OPEN_SCHEMES` |
| file / directory | `explorer.exe <winpath>`; paths with `,` or exotic characters → PowerShell `Start-Process -LiteralPath` (base64-passed) |
| `.exe .bat .ps1 .lnk .hta .msi .url .reg .iso …` | **refused** (ShellExecute would run/mount them) unless `--force`; also enforced for `file://` URIs |
| `C:\…`, `\\wsl.localhost\…` arguments | translated back and treated as paths |
| `--reveal` | `explorer.exe /select,"…"` via PowerShell |
| `--editor[=code|cursor|windsurf]` | integrated-terminal remote CLI, else the Windows launcher script (Remote-WSL) |
| `--default-browser` | `reg.exe` query of the https `UserChoice` ProgId |

`/etc/profile.d/20-omarchy-browser.sh` exports `BROWSER=omarchy-open` (only if unset) so `gh`, `npm login`, `python -m webbrowser`, `cargo doc --open` and Jupyter use it.

---

## Domain 6: Windows Toast Notification Bridge

### Findings
- Windows Terminal: **OSC 9;4** taskbar/tab progress since 1.6 (states 0 clear, 1 normal, 2 error, 3 indeterminate, 4 warning); **OSC 777;notify** only in Preview 1.26.2734+ behind `"compatibility.allowOSC777": true`, suppressed while WT is focused; plain OSC 9 text notifications are **not** implemented. `bellStyle: "taskbar"` flashes the taskbar on BEL.
- WinRT type loading (`[…, ContentType=WindowsRuntime]`) works in **Windows PowerShell 5.1** only; .NET 5+ removed built-in WinRT, so pwsh 7 needs BurntToast (1.1.0) or C#/WinRT projections.
- Unpackaged AppUserModelIDs: `HKCU\Software\Classes\AppUserModelId\<id>` with `DisplayName`/`IconUri` works in practice (used by Windows-Toasts) but is undocumented; Microsoft's older guidance requires a Start-menu shortcut.
- Toast images: PNG/JPG/GIF, `file:///` allowed for desktop apps, **not ICO/SVG**. Sounds: `ms-winsoundevent:*` only — custom files require package identity.

### Engineering — `omarchy-notify`
```bash
omarchy-notify -l success "Build finished" "cargo build --release"
omarchy-notify --wrap -- cargo test             # status + duration, taskbar progress while running
omarchy-build --notify cargo build --release    # same, inside build.slice
long-agent-task; omarchy-notify "Agent task complete"
```
- Title/body/icon/AUMID are base64 literals decoded inside PowerShell and XML-escaped there (`SecurityElement.Escape`); C0 controls are stripped (XML 1.0 rejects them); title ≤ 128, body ≤ 1024 chars.
- AUMID `Omarchy.WSL` is self-registered under HKCU on first use; override with `--app-id` / `OMARCHY_NOTIFY_APP_ID` if your Windows build ignores registry AUMIDs.
- Tokyo Night icons (info/success/warning/error, 128 px RGBA) are generated reproducibly by `tools/generate-notify-icons.py` (stdlib only, byte-identical output) and mirrored to `%LOCALAPPDATA%\Omarchy\notify` because toasts cannot load `\\wsl.localhost` images.
- Fire-and-forget by default (PowerShell start-up never delays the shell); `--sync` waits. Without interop (SSH) it emits OSC 777 + OSC 9 + BEL, tmux-passthrough aware, with `;` removed from fields.
- `--wrap` always returns the wrapped command's exit status.

---

## Domain 7: Audio, Microphone & the WSLg Pipeline

### Findings
- WSLg's PulseAudio server runs in the system distro; user distros see `/mnt/wslg/PulseServer` and `/mnt/wslg/runtime-dir/pulse`. Audio goes to Windows over RDP (`RDPSink`, `RDPSource`).
- WSL sets `PULSE_SERVER` only for wsl.exe sessions. **systemd --user services do not inherit it**, and systemd mounts a fresh tmpfs on `/run/user/$UID`, hiding the WSLg `pulse`/`wayland-0` entries (ArchWSL#357; AlmaLinux ships tmpfiles symlinks).
- `client.conf` keys: `default-server`, `autospawn`, `enable-shm`, `enable-memfd`, `shm-size-bytes`, … — **no latency key**. Drop-ins in `client.conf.d/` are honoured; **a user `~/.config/pulse/client.conf` suppresses `/etc/pulse/` entirely**; `$PULSE_SERVER` beats `default-server`.
- **Crackling is an open, unfixed server-side issue** (wslg#1429: RDPSink underruns, "no userspace workaround effective"). `PULSE_LATENCY_MSEC` / `enable-shm=no` advice is folklore without official backing.
- Installing pipewire-pulse inside a systemd distro breaks WSLg audio for clients that don't set `PULSE_SERVER` (WSL discussion #11406).
- Microphone: `RDPSource` occasionally disappears; reload with `pactl load-module module-rdp-source source_name=RDPSource`. Windows' microphone privacy toggles ("Let desktop apps access your microphone") must allow it.

### Engineering
| File | Purpose |
|:--|:--|
| `/etc/pulse/client.conf.d/wslg.conf` | `default-server = unix:/mnt/wslg/PulseServer`, `autospawn = no` (no hijacking local daemon), `enable-memfd = yes` (client and server share the utility-VM kernel; `/dev/shm` is per distro), 64 MiB shm pool for long STT captures |
| `/usr/lib/environment.d/50-omarchy-wslg.conf` | `PULSE_SERVER`, `PULSE_LATENCY_MSEC=60` for every systemd --user service |
| `/usr/share/user-tmpfiles.d/omarchy-wslg.conf` | `L %t/pulse`, `%t/wayland-0[.lock]` → `/mnt/wslg/runtime-dir/…`; `L` (not `L+`) never replaces a deliberately installed pipewire-pulse |
| `/etc/alsa/conf.d/99-omarchy-wslg-pulse.conf` | Raw ALSA apps (`arecord`, whisper.cpp, sox) → pulse plugin (WSL2 has no ALSA hardware) |
| `/etc/profile.d/20-omarchy-wslg-audio.sh` | Session defaults when the WSLg socket exists |
| packages | `libpulse` (pactl/paplay/parecord), `alsa-plugins` |

**STT smoke test**
```bash
pactl info | grep -E 'Server Name|Default Source'
parecord --channels=1 --rate=16000 --format=s16le --file-format=wav /tmp/mic.wav   # Ctrl-C after a few seconds
paplay /tmp/mic.wav
PULSE_LATENCY_MSEC=20 mpv song.flac          # per-app override when latency matters more than underruns
systemctl --user mask pipewire-pulse.socket pipewire-pulse.service   # if pipewire got pulled in
```

---

## Domain 8: Docker & Podman Host Engine Bridge

### Findings
- **Docker Desktop WSL integration** symlinks the CLI to `/mnt/wsl/docker-desktop/cli-tools/usr/bin/`, creates `/var/run/docker.sock` + `docker-cli.sock`, and shares `/mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.sock`. It breaks when the distro's login shell is fish/csh/tcsh, and conflicts with Docker packages installed in the distro. Any distro is supported.
- Without integration: `\\.\pipe\docker_engine` via `npiperelay -ep -s`.
- **Podman machine** exposes `/mnt/wsl/podman-sockets/<machine>/podman-{root,user}.sock`; write access is via GID 10, whose name differs per distro (wheel on Fedora, uucp on Ubuntu) — on Omarchy check `getent group 10`, create a group with that GID if it is free, and join it. Windows pipe: `\\.\pipe\podman-machine-default`.
- Native rootless Podman: `systemctl --user enable --now podman.socket` → `$XDG_RUNTIME_DIR/podman/podman.sock`. Testcontainers needs only `DOCKER_HOST` on Linux, plus `TESTCONTAINERS_RYUK_DISABLED=true` for rootless.
- `connect()` follows symlinks to Unix sockets (verified).
- `DOCKER_HOST` overrides `docker context` — exporting it unconditionally would silently break users of remote contexts.

### Engineering — `omarchy-docker-bridge`
```
$XDG_RUNTIME_DIR/omarchy/docker.sock ──(atomic symlink)──► desktop | docker | docker-rootless | podman | podman-machine
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/omarchy/docker.sock
```
```bash
omarchy-docker-bridge status            # health via GET /_ping on every candidate socket
omarchy-docker-bridge use podman        # starts podman.socket if needed; persists preference
omarchy-docker-bridge use auto          # desktop > docker > docker-rootless > podman > podman-machine
omarchy-docker-bridge relay desktop     # no WSL integration? relay \\.\pipe\docker_engine
omarchy-docker-bridge install-system    # optional /run/docker.sock symlink via tmpfiles.d (sudo)
omarchy-docker-bridge off
```
Switching engines re-points one symlink, so already-open shells follow without re-exporting. A native `/run/docker.sock` that Docker Desktop materialised is reported as `managed-by-desktop`, not as a native daemon. `install-system` refuses to replace any live socket or foreign symlink. `profile.d` exports nothing until the user opts in.

---

## Domain 9: Inotify Bridge (Windows Edits → Linux Hot-Reload)

### Findings
- Linux inotify receives **no events on `/mnt/<drive>` for changes made by Windows processes** (microsoft/WSL#4739, open; inotify(7): remote changes on network filesystems are not reported). Raising `max_user_watches` does not help.
- Edits from Windows into ext4 via `\\wsl.localhost` are performed by WSL's 9P server *inside* Linux and therefore go through the VFS (reported working by third parties; Microsoft documents nothing either way). Linux-side `utimensat`/`open` on DrvFs are VFS calls and raise local events (inference from fsnotify design — **verified live by our test suite with inotifywait**).
- No "wsl-notify-forwarder" exists. Related prior art: `thekid/inotify-win` (inotifywait port for Windows), `int128/idea-fsnotifier-wsl` (WSL1 era), wslkit#29 (proposal). VS Code Remote-WSL runs its watcher inside Linux (`remote.WSL.fileWatcher.polling` as fallback).
- `.NET FileSystemWatcher`: `InternalBufferSize` 4 KiB–64 KiB (non-paged pool); `WaitForChanged` drops events between calls — use event subscription.
- Polling knobs: `CHOKIDAR_USEPOLLING`/`CHOKIDAR_INTERVAL` (still honoured), `WATCHPACK_POLLING` (webpack only — **Turbopack ignores it**; Next.js uses `watchOptions.pollIntervalMs`), Vite `server.watch.usePolling`, `cargo watch --poll`, `watchexec --poll 500ms` (**default interval is 30 s**), `nodemon -L`, `TSC_WATCHFILE`/`TSC_WATCHDIRECTORY`.
- `max_user_watches` defaults to ~1 % of RAM, clamped 8 192 – 1 048 576 (kernel ≥ 5.11).

### Engineering — guidelines first, bridge second
1. **Recommended:** keep projects in `~/src` (ext4) and open them from Windows as `\\wsl.localhost\Omarchy\home\<you>\src\…` or with `code --remote wsl+Omarchy`. Native inotify, full speed, no bridge.
2. **`omarchy-watch-bridge run <dir>`** when the tree must stay on a Windows drive:
   - Windows side: `FileSystemWatcher` (64 KiB buffer, `Register-ObjectEvent` queue, excludes `node_modules .git target dist .next .turbo .cache __pycache__`), streaming `Type<TAB>Path`; overflow events are surfaced.
   - Linux side: each change becomes `touch -c -r f f` (**IN_ATTRIB**, mtime preserved so mtime-comparing watchers see Windows' timestamp) plus an empty open-for-append (**IN_CLOSE_WRITE** for `entr`/`inotifywait`); deletes touch the parent directory; overflow touches the root; per-path suppression (default 750 ms) coalesces bursts and our own echoes.
3. **Last resort:** `eval "$(omarchy-watch-bridge env)"` (polling env + per-tool flags).
```bash
omarchy-watch-bridge check .        # diagnosis + exact relocation commands
omarchy-watch-bridge run /mnt/c/src/app &
npm run dev
```

---

## Domain 10: Battery, AC Power & Thermal Governor

### Findings
- WSL2 supports **battery/AC passthrough** (release notes, build 18980). On **arm64 kernels it is built in; on x86 6.6.y/6.18.y kernels `CONFIG_ACPI_BATTERY`/`CONFIG_ACPI_AC` are modules**, so x86 hosts frequently show an empty `/sys/class/power_supply`. Device names vary — detect by `type`.
- Host APIs without admin: `SystemInformation.PowerStatus` (`BatteryLifePercent` is a **0.0–1.0 float**; `NoSystemBattery` flag on desktops), `PowerManager.EnergySaverStatus` (Disabled/Off/On), power-mode overlay GUIDs (best efficiency `961cc777-…`, better performance `3af9b8d9-…`, best performance `ded574b5-…`, balanced = all zeros; registry location community-sourced, `powercfg /getactivescheme` does **not** reflect it).
- Throttling: `Processor Information\% Performance Limit` and `Thermal Zone Information\% Passive Limit`. Counter *paths* are localised, so the governor reads the locale-independent WMI classes (`Win32_PerfFormattedData_Counters_ProcessorInformation.PercentPerformanceLimit`, `…ThermalZoneInformation.PercentPassiveLimit`). `MSAcpi_ThermalZoneTemperature` needs admin and often reports constants.
- Snapdragon X Elite: 12 identical Oryon cores (3×4); X2 Elite: 12 Prime + 6 Performance. WSL vCPUs do not expose this split, so battery state, not core type, must drive parallelism.

### Engineering — `omarchy-power-governor`
| Condition | Factor |
|:--|:--|
| AC | 100 % |
| Battery | 50 % (`OMARCHY_POWER_BATTERY_PCT`) |
| Battery ≤ 20 % or Energy Saver on | 25 % (`OMARCHY_POWER_LOW_PCT`) |
| Power mode "best power efficiency" | ≤ battery factor |
| Performance/passive limit < 80 % | × limit / 100 |
| Floor | never below 1 job |

Signals: sysfs first, Windows query to fill gaps (one PowerShell process, cached 60 s in the runtime dir). PowerShell output and the config file (`~/.config/omarchy/power-governor.conf`) are **parsed against whitelists, never sourced or evaluated**.
```bash
omarchy-power-governor status          # human
omarchy-power-governor status --json   # machine
omarchy-power-governor jobs 12         # → 6 on battery
omarchy-build cargo build --release    # [omarchy-build] power governor: -j8 -> -j4
omarchy-build -j 12 make               # explicit -j always wins
omarchy-build --no-power …             # opt out per build; OMARCHY_POWER_GOVERNOR=off globally
```
`omarchy-build` also gained `--notify`, `--dry-run`, and a DrvFs refusal (`--allow-drvfs` to override).

---

## 11. Verification

```bash
bash tests/test_windows_integration.sh
SHELLCHECK=/path/to/shellcheck PWSH=/path/to/pwsh bash tests/test_windows_integration.sh   # full strength
OMW_TEST_KEEP=1 bash tests/test_windows_integration.sh                                  # keep the sandbox
```
The suite builds a fake Windows host (DrvFs tree with `C:`/`D:`, a `Jane Doe` profile with a space, and stub `powershell.exe` / `cmd.exe` / `clip.exe` / `rundll32.exe` / `explorer.exe` / `reg.exe` that record argv, stdin and the *decoded* `-EncodedCommand` scripts) and runs the real tools against it:

| Area | Highlights |
|:--|:--|
| Static | `bash -n`, `sh -n` for profile.d, strict mode, shellcheck `-S warning`, no `eval`, no `cmd.exe` with user data, PowerShell only via `-EncodedCommand`, **every generated PowerShell script parsed by pwsh** |
| Interop lib | path translation incl. drive roots/UNC/foreign distros, custom automount root, mountinfo DrvFs detection incl. prefix confusion, 0700 runtime dir |
| Launcher | Follina/search-ms/javascript refusal, percent-encoding, executable guard incl. `file://` and `.LNK`, argv integrity |
| Clipboard | UTF-16LE BOM, exact CRLF, byte-identical PNG round-trip, OSC 52 framing + tmux DCS, size refusal, stdin isolation |
| Known Folders & guard | OneDrive/D: relocation, no clobbering, idempotence, dry-run; guard blocks/allows correctly, symlink resolution, user functions preserved |
| SSH agent | live ssh-agent behind the bridge, `0600` socket, foreign-agent refusal, signing with the private key deleted, Pageant pipe discovery |
| Git credentials | CR stripping, WSLENV/GCM_INTERACTIVE, gh fallback, malformed-input rejection, install/uninstall round-trip, ucrt64/clangarm64 discovery |
| Toasts | hostile titles never reach script text, icons mirrored, sounds, OSC 777 sanitisation, exit-status preservation |
| Containers | fake Docker API servers, auto preference, route switching, end-to-end `/_ping`, Ryuk hint, live-socket protection |
| Watcher | ctime changes / mtime and content preserved, exclusions, coalescing, **real inotify IN_ATTRIB + IN_CLOSE_WRITE**, parent touch on delete |
| Power | sysfs AC/battery/low, Windows fallback, Energy Saver, overlay, thermal limit, NoSystemBattery, cache, hostile output/config, `omarchy-build` integration |
| Artefacts | audio/env/tmpfiles/ALSA, `.reg` HKCU-only + `%V.`, systemd unit, packages, Containerfile coverage |

**What the suite cannot prove** (needs a real Windows 11 host): toast rendering and registry-AUMID acceptance, WSLg clipboard/audio behaviour, Quick Access pinning of `\\wsl.localhost` paths, Explorer verb placement, GCM OAuth UI, and real `npiperelay` named-pipe I/O.

---

## 12. References

- WSL: release notes & `wsl.conf` — learn.microsoft.com/windows/wsl/release-notes, /wsl-config; microsoft/WSL#4739, #5961, PR #41780; `src/linux/init/binfmt.h`
- WSLg: github.com/microsoft/wslg (README; issues #236, #294, #684, #743, #833, #908, #1202, #1220, #1326, #1429, #1499, #1512); microsoft/WSL discussion #11406; yuk7/ArchWSL#357
- Windows Terminal: learn.microsoft.com/windows/terminal/{command-line-arguments, tutorials/progress-bar-sequences, customize-settings/profile-advanced}; microsoft/terminal#4571, PR #5823, PR #20012, release v1.26.2734.0
- Shell: learn.microsoft.com/windows/win32/shell/knownfolderid; devblogs.microsoft.com/oldnewthing/20031103-00/?p=41973; Windows 11 context-menu extensibility (blogs.windows.com, 2021-07-19)
- PowerShell: about_powershell_exe / about_pwsh; Get-Clipboard 5.1 vs 7.5; language spec chapter 2 (quote characters); .NET 5 WinRT removal notice
- Toasts: toast schema `image`/`audio` elements; app-notifications schema; DatGuy1/Windows-Toasts; BurntToast 1.1.0
- SSH/GPG: albertony/npiperelay; jstarks/npiperelay; rupor-github/wsl-ssh-agent; 1password.dev/ssh (get-started, integrations/wsl); bitwarden.com/help/ssh-agent; KeePassXC user guide; PuTTY manual ch. 9; GnuPG commit 0802cbb; libassuan socket wrappers; gpg4win change history
- Git: git-ecosystem/git-credential-manager docs/wsl.md, `StandardStreams.cs`, `GitHubConstants.cs`; cli/cli `oauth_scopes.go`, `gitcredential/helper.go`
- wslu: github.com/wslutilities/wslu (archived); CVE-2026-54699; LOLBAS url.dll; CVE-2022-30190
- Containers: docs.docker.com/desktop/features/wsl; docker/for-win#13783; podman-desktop.io (WSL access, DOCKER_HOST); docs.podman.io podman-system-service; java.testcontainers.org supported environments
- Watching: inotify(7); vite.dev server options; webpack/watchpack; Next.js PR #97673; watchexec(1); cargo-watch(1); nodemon; TypeScript configuring-watch; FileSystemWatcher.InternalBufferSize; dotnet/runtime FileSystemWatcher.cs; thekid/inotify-win
- Power: SystemInformation.PowerStatus / BatteryLifePercent; Win32_Battery; PowerManager.EnergySaverStatus; customize-power-slider; microsoft/WSL2-Linux-Kernel `config-wsl`; prometheus-community/windows_exporter collectors
