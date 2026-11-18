# Omarchy-WSL Cross-OS Theme Synchronization Engine

## 1. Architectural Overview

The **Omarchy-WSL Theme Synchronization Engine** (`/usr/bin/omarchy-theme-sync`, Python package installed at `/usr/lib/omarchy-wsl/python/omarchy_theme`) applies one color scheme to:
- **Windows Terminal** (Stable, Preview and Canary MSIX packages, and the unpackaged `%LOCALAPPDATA%\Microsoft\Windows Terminal` location)
- **VS Code** (Windows Stable, Insiders, VSCodium, and the WSL VS Code Server machine settings)
- **Linux terminal emulators**: Ghostty, Kitty and Alacritty, each only when it is installed (binary on `PATH`) or already configured. WezTerm configs are detected and listed by `--status`, but no WezTerm adapter exists.

Every change is a locked, atomic read-modify-write with backups; unchanged files are not rewritten.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Omarchy Linux (WSL2)                           │
│                                                                        │
│   /bin/omarchy-theme-sync --theme tokyo-night                          │
│        │                                                               │
│        ├─── lib/omarchy_theme/models.py (ANSI 16 + UI color tokens)    │
│        ├─── lib/omarchy_theme/palettes.py (Canonical palettes)         │
│        ├─── lib/omarchy_theme/jsonc.py (Comment-preserving JSONC AST)  │
│        ├─── lib/omarchy_theme/detector.py (Multi-variant locator)      │
│        └─── lib/omarchy_theme/atomic_io.py (locked atomic updates)     │
└───────┬───────────────────────────────┬────────────────────────────────┘
        │                               │
        ▼ (DrvFS / Interop)             ▼ (Local configs)
┌───────────────────────────────┐ ┌──────────────────────────────────────┐
│        Windows Host           │ │         Linux Native                 │
│                               │ │                                      │
│ • Windows Terminal            │ │ • ghostty/config (managed block)     │
│   %LOCALAPPDATA%\Packages\... │ │ • alacritty/omarchy-theme.toml       │
│   settings.json               │ │   (+ one general.import entry)       │
│ • VS Code                     │ │ • kitty/current-theme.conf           │
│   %APPDATA%\Code\User\...     │ │   (+ one include line)               │
│   settings.json               │ └──────────────────────────────────────┘
└───────────────────────────────┘
```
Linux paths are relative to `$XDG_CONFIG_HOME` (default `~/.config`).

---

## 2. Adversarial Threat Model & Mitigations

### 2.1 Multi-Variant Windows Terminal Discovery

| Installation Type | Location Path | Detection Mechanism |
|---|---|---|
| **Stable MSIX** | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` | Scans for package directories starting with `Microsoft.WindowsTerminal_` (tolerating store package hash shifts). |
| **Preview MSIX** | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json` | Scans for package directories matching `Microsoft.WindowsTerminalPreview_*`. |
| **Canary MSIX** | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json` | Scans for package directories matching `Microsoft.WindowsTerminalCanary_*`. |
| **Unpackaged / Portable** | `%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json` | Checks directory path directly. |
| **Windows 10 vs 11** | Same relative path structure across builds | Build numbers >= 19041 supported. |

#### WSL Path Resolution & Interop Fallback
1. **Mode A (Interop Active)**:
   - Executes `cmd.exe /c "echo %LOCALAPPDATA%"` and translates via `wslpath -u` or `/mnt/<drive>/...`.
2. **Mode B (Interop Disabled / `binfmt_misc` Unregistered)**:
   - Scans mounted DrvFS drives (`/proc/mounts`) under `/mnt/c/Users/` or `/c/Users/`.
   - Discards system user accounts (`Public`, `Default`, `All Users`).
   - Identifies active user directories via `AppData/Local` and `NTUSER.DAT`.
   - Resolves target paths without executing any Win32 binaries.
3. **Mode C (Pure Linux / Disconnected Host)**:
   - If no DrvFS drives are attached, cleanly skips Windows targets with an informational message and syncs local Linux terminal emulators.

---

### 2.2 Concurrent Access, File Locking & Zero Corruption

Windows Terminal watches `LocalState` and hot-reloads `settings.json`. A naive in-place write (`O_TRUNC`) can be read while empty or half-written. Two syncs at once (two Linux users, two distros, two terminals) can also interleave their read-modify-write cycles and silently drop each other's scheme.

#### The update protocol (`atomic_io.atomic_update_text`)
1. **Lock**: an exclusive `O_CREAT | O_EXCL` lock file `settings.json.omarchy-lock` next to the target guards the whole read → modify → backup → rename transaction (`flock` is not used: it is unreliable on DrvFs). A stale lock is broken when its holder PID is dead in the same PID namespace, or when it is older than 60 s; the lock is renamed away and verified first, so a fresh lock of another process is never deleted. Waiting is bounded (30 s by default).
2. **Read & transform**: the current text is read under the lock and edited by the JSONC modifier, which parses its own output again after every edit and checks that the scheme it wrote is present. Any parse error aborts the transaction with the file untouched.
3. **Skip no-ops**: if the new text equals the current content, nothing is written and no backup is rotated.
4. **Stage**: the content goes to `settings.json.omarchy_tmp.<pid>.<ns>.<nonce>` in the same directory, is flushed and `fsync`ed, gets the original file's mode, and is checked to be non-empty.
5. **Backups**: the first change ever also keeps `settings.json.omarchy-orig` (never rotated). Every change rotates `settings.json.bak` → `.bak.1` → `.bak.2` (three generations); files vanishing underneath are tolerated.
6. **Commit**: after re-checking that this process still owns the lock, `os.replace` (atomic `rename(2)`) swaps the staged file in. Transient `PermissionError`/`OSError` (sharing violations from WT, an editor or antivirus) are retried up to 5 times with exponential backoff (50, 100, 200, 400, 800 ms).
7. **Fail closed**: a file with pre-existing syntax errors is never modified; the error position is reported.

---

### 2.3 JSONC Comment & Structure Preservation

Standard `json.loads()` and `ConvertFrom-Json` fail on comments (`//`, `/* */`) and trailing commas. Furthermore, dumping via `json.dumps()` strips all user comments throughout the file.

`lib/omarchy_theme/jsonc.py` implements a lossless lexical tokenizer and surgical AST modifier:
- Differentiates strings (including escaped quotes and embedded `//` or URLs) from comments.
- Locates the exact character spans of `"schemes"` and `"profiles"`.
- If the target scheme already exists, it updates only that scheme object.
- If the scheme does not exist, it appends it to `"schemes"`.
- Updates only the `colorScheme` property inside the target profile object (e.g. `"Omarchy"`).
- **Preserves user comments, whitespace and keybindings outside the modified spans.** Comments *inside* a replaced scheme object, or inside VS Code's `workbench.colorCustomizations` object when it is rewritten, are not kept.

---

### 2.4 Color Palette Mapping & Schema Normalization

| Component | Target Property Format | Crucial Schema Quirks |
|---|---|---|
| **Windows Terminal** | `black`, `red`, `green`, `yellow`, `blue`, **`purple`**, `cyan`, `white`<br>`brightBlack`, `brightRed`, `brightGreen`, `brightYellow`, `brightBlue`, **`brightPurple`**, `brightCyan`, `brightWhite`<br>`background`, `foreground`, `cursorColor`, `selectionBackground` | Requires **`purple`** (NOT `magenta`) and **`brightPurple`** (NOT `brightMagenta`). If `magenta` is used, WT drops the value and falls back to default. |
| **VS Code** | `workbench.colorCustomizations`:<br>`terminal.ansiBlack` through `terminal.ansiWhite`<br>`terminal.ansiMagenta`, `terminal.ansiBrightMagenta`<br>`terminal.background`, `terminal.foreground`<br>`workbench.colorTheme` | Uses **`terminal.ansiMagenta`**. Terminal colors are set directly. When the palette names a VS Code theme, `workbench.colorTheme` is set too (this replaces the user's chosen theme). |
| **Ghostty** | `palette = 0=#hex` through `15=#hex`, `background`, `foreground`, `cursor-color`, `selection-background` | Written between `# >>> omarchy-theme-sync (managed block, do not edit) >>>` and `# <<< omarchy-theme-sync <<<` at the end of the config; only that block is ever replaced. Unmarked blocks written by older versions are removed only on an exact structural match. |
| **Alacritty** | `[colors.primary]`, `[colors.cursor]`, `[colors.selection]`, `[colors.normal]`, `[colors.bright]` in `omarchy-theme.toml` | `alacritty.toml` only gains one `general.import` entry (added to an existing `import` array if there is one); its other tables, e.g. `[[keyboard.bindings]]`, are untouched. The edit is checked with `tomllib`: anything other than the added import changing aborts it. Colors defined directly in `alacritty.toml` still win (imports load first); the result message says so. |
| **Kitty** | `current-theme.conf` included by `kitty.conf` | `color0` through `color15`; the `include` line is added once. |

Theme names are sanitized before they reach any file: control characters (newlines included) become spaces and names are capped at 64 characters, so a crafted palette name cannot inject configuration lines. `--dry-run` reads only: no file or directory is created.

#### Canonical Built-in Palettes:
- **Tokyo Night** (Classic `#1a1b26` & Storm variant `#24283b`)
- **Catppuccin** (Mocha `#1e1e2e`, Macchiato `#24273a`, Frappe `#303446`, Latte `#eff1f5`)
- **Nord** (`#2e3440` Polar Night, Frost, Aurora)
- **Dracula** (`#282a36`)
- **Gruvbox Dark** (`#282828`)
- **One Dark** (`#282c34`)
- **Solarized Dark** (`#002b36`)

---

## 3. CLI & Script Usage

### Python Engine (`/usr/bin/omarchy-theme-sync`)

```bash
# List available built-in themes
omarchy-theme-sync --list-themes

# Preview changes without modifying files (dry-run)
omarchy-theme-sync --theme tokyo-night --dry-run

# Apply theme to Omarchy profile in Windows Terminal + VS Code + Linux terminals
omarchy-theme-sync --theme tokyo-night

# Apply theme globally to all Windows Terminal profiles (profiles.defaults)
omarchy-theme-sync --theme catppuccin-mocha --set-wt-default

# Apply custom theme from TOML or JSON file
omarchy-theme-sync --theme /path/to/my-theme.toml

# Audit detected environments and target files
omarchy-theme-sync --status

# Rollback targets from latest safety backup
omarchy-theme-sync --restore
```

### Windows-side script (`bin/sync-theme.ps1`)

A standalone PowerShell 5.1 script for Windows Terminal only (no VS Code), installed as `/usr/share/omarchy-wsl/windows/sync-theme.ps1`. Run it on Windows; `Get-Help .\sync-theme.ps1 -Full` documents its parameters (`-Theme`, `-ProfileName`, `-ApplyToDefaults`, `-DryRun`, `-Status`, `-Restore`, `-RestoreFrom`, `-ListThemes`). `-Restore` puts back the untouched original (`settings.json.omarchy-orig`, written once and never overwritten); `-Restore -RestoreFrom Latest` uses the newest rotating `settings.json.bak` instead.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\sync-theme.ps1 -Theme TokyoNight
powershell.exe -ExecutionPolicy Bypass -File .\sync-theme.ps1 -Theme Nord -ApplyToDefaults
powershell.exe -ExecutionPolicy Bypass -File .\sync-theme.ps1 -Restore
```

---

## 4. Verification

`python3 -m pytest -q` (repository root; `pyproject.toml` puts `lib/` on the path) and `OMW_STRICT=1 bash tests/test_theme_adversarial.sh`:
- **`tests/test_jsonc.py`**: Comments, block comments, trailing commas, URLs with slashes, BOM handling, syntax error reporting, and surgical modification.
- **`tests/test_palettes.py`**: Hex normalization, ANSI 16 accuracy, Windows Terminal schema conformance (`purple` vs `magenta`), and VS Code token mappings.
- **`tests/test_atomic_io.py`**: Atomic replacement, staging cleanup, backup rotation (three generations plus `.omarchy-orig`), ENOENT-tolerant rotation, no-op skip, mode preservation, sharing-violation retries, live/stale/dead-holder lock files, and 12 concurrent processes × 15 syncs against one `settings.json` with no lost update.
- **`tests/test_detector.py`**: Multi-variant Windows Terminal detection, VS Code detection, WSL interop disabled fallback, and headless degradation.
- **`tests/test_adversarial.py`**: Pre-existing corruption fail-closed safety, complex configuration preservation, rapid consecutive updates, CLI return codes; Alacritty bindings/colors preserved and import idempotent, legacy-block cleanup, invalid TOML fails closed, Ghostty single managed block, Kitty single include, uninstalled terminals untouched, dry-run without mkdir, theme-name injection, and the installed `/usr/lib/omarchy-wsl/python` layout.
- **`tests/test_theme_adversarial.sh`**: the CLI end to end in a sandboxed `HOME` (dry-run side effects, Linux terminal syncs, installed layout) and a `pwsh` parse of `sync-theme.ps1`.
