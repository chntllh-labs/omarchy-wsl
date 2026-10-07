# Omarchy-WSL Cross-OS Theme Synchronization Engine

## 1. Architectural Overview

The **Omarchy-WSL Theme Synchronization Engine** provides atomic, zero-data-loss theme propagation between Omarchy Linux (WSL2) and the Windows host environment. It dynamically synchronizes terminal color schemes, editor tokens, and profile definitions across:
- **Windows Terminal** (Stable MSIX, Preview MSIX, Canary, Unpackaged, Portable)
- **VS Code** (Windows Stable, Insiders, VSCodium, WSL Remote Server)
- **Linux Terminal Emulators** (Ghostty, Alacritty, Kitty, WezTerm)

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
│        └─── lib/omarchy_theme/atomic_io.py (NTFS/DrvFS atomic swap)    │
└───────┬───────────────────────────────┬────────────────────────────────┘
        │                               │
        ▼ (DrvFS / Interop)             ▼ (Local configs)
┌───────────────────────────────┐ ┌──────────────────────────────────────┐
│        Windows Host           │ │         Linux Native                 │
│                               │ │                                      │
│ • Windows Terminal            │ │ • ~/.config/ghostty/config           │
│   %LOCALAPPDATA%\Packages\... │ │ • ~/.config/alacritty/alacritty.toml │
│   settings.json               │ │ • ~/.config/kitty/current-theme.conf │
│ • VS Code                     │ │ • ~/.config/wezterm/wezterm.lua      │
│   %APPDATA%\Code\User\...     │ └──────────────────────────────────────┘
│   settings.json               │
└───────────────────────────────┘
```

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

Windows Terminal maintains an active `ReadDirectoryChangesW` file watcher on `LocalState`. A naive in-place write (`O_TRUNC` or standard file overwrite) triggers hot-reload while the file has zero bytes or is half-written, causing Windows Terminal to display syntax error popups or reset settings to factory defaults.

#### The Omarchy Atomic Protocol:
1. **Staging in Target Directory**:
   Writes content to `settings.json.omarchy_tmp.<PID>.<TIMESTAMP>.<NONCE>` in the exact same directory (preventing cross-device link errors across NTFS/DrvFS).
2. **Buffer Flush & fsync**:
   Forces `flush()` and `os.fsync()` before file swap to ensure data reaches persistent storage before the directory pointer changes.
3. **Pre-Swap Verification**:
   The engine parses the staging file back to ensure:
   - The file is non-empty.
   - The JSONC syntax is 100% valid.
   - The target scheme and profile changes are present.
4. **Safety Backup Rotation**:
   Copies `settings.json` to `settings.json.bak` and rotates existing backups (`.bak.1`, `.bak.2`).
5. **Atomic Replacement (`os.replace` / Win32 `ReplaceFile`)**:
   Swaps the temporary file onto the target atomically.
6. **Transient Sharing-Violation Retry Loop**:
   If Windows Terminal or an external editor holds a transient read lock (`ERROR_SHARING_VIOLATION` / `PermissionError`), the engine retries up to 5 times with exponential backoff (50ms, 100ms, 200ms, 400ms, 800ms).
7. **Fail-Closed Safety**:
   If existing `settings.json` has pre-existing syntax errors before Omarchy touches it, the engine **refuses to modify the file**, logs the line/column number of the syntax error, and leaves the file untouched.

---

### 2.3 JSONC Comment & Structure Preservation

Standard `json.loads()` and `ConvertFrom-Json` fail on comments (`//`, `/* */`) and trailing commas. Furthermore, dumping via `json.dumps()` strips all user comments throughout the file.

`lib/omarchy_theme/jsonc.py` implements a lossless lexical tokenizer and surgical AST modifier:
- Differentiates strings (including escaped quotes and embedded `//` or URLs) from comments.
- Locates the exact character spans of `"schemes"` and `"profiles"`.
- If the target scheme already exists, it updates only that scheme object.
- If the scheme does not exist, it appends it to `"schemes"`.
- Updates only the `colorScheme` property inside the target profile object (e.g. `"Omarchy"`).
- **Preserves 100% of user comments, whitespace, and custom keybindings outside the modified spans.**

---

### 2.4 Color Palette Mapping & Schema Normalization

| Component | Target Property Format | Crucial Schema Quirks |
|---|---|---|
| **Windows Terminal** | `black`, `red`, `green`, `yellow`, `blue`, **`purple`**, `cyan`, `white`<br>`brightBlack`, `brightRed`, `brightGreen`, `brightYellow`, `brightBlue`, **`brightPurple`**, `brightCyan`, `brightWhite`<br>`background`, `foreground`, `cursorColor`, `selectionBackground` | Requires **`purple`** (NOT `magenta`) and **`brightPurple`** (NOT `brightMagenta`). If `magenta` is used, WT drops the value and falls back to default. |
| **VS Code** | `workbench.colorCustomizations`:<br>`terminal.ansiBlack` through `terminal.ansiWhite`<br>`terminal.ansiMagenta`, `terminal.ansiBrightMagenta`<br>`terminal.background`, `terminal.foreground`<br>`workbench.colorTheme` | Uses **`terminal.ansiMagenta`**. Injects direct terminal customizations so integrated terminal matches theme without requiring third-party extension installation. |
| **Ghostty** | `palette = 0=#hex` through `15=#hex`, `background`, `foreground`, `cursor-color`, `selection-background` | Direct palette index assignment. |
| **Alacritty** | `[colors.primary]`, `[colors.cursor]`, `[colors.selection]`, `[colors.normal]`, `[colors.bright]` | Standard TOML color tables. |
| **Kitty** | `current-theme.conf` included by `kitty.conf` | `color0` through `color15`. |

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

### PowerShell Companion Script (`bin/sync-theme.ps1`)

Can be invoked directly from Windows PowerShell or from WSL via PowerShell interop:

```powershell
# Windows Terminal & VS Code sync from Windows host
powershell.exe -ExecutionPolicy Bypass -File .\bin\sync-theme.ps1 -Theme TokyoNight

# Apply to all profiles as default
powershell.exe -ExecutionPolicy Bypass -File .\bin\sync-theme.ps1 -Theme Nord -ApplyToDefaults

# Rollback from .bak
powershell.exe -ExecutionPolicy Bypass -File .\bin\sync-theme.ps1 -Restore
```

---

## 4. Verification and Proofing Results

The test suite validates the engine across 36 unit and adversarial test scenarios:
- **`tests/test_jsonc.py`**: Comments, block comments, trailing commas, URLs with slashes, BOM handling, syntax error reporting, and surgical modification.
- **`tests/test_palettes.py`**: Hex normalization, ANSI 16 accuracy, Windows Terminal schema conformance (`purple` vs `magenta`), and VS Code token mappings.
- **`tests/test_atomic_io.py`**: Atomic replacement, staging file cleanup, backup rotation, transient sharing violation retries, and permanent lock defense.
- **`tests/test_detector.py`**: Multi-variant Windows Terminal detection, VS Code detection, WSL interop disabled fallback, and headless degradation.
- **`tests/test_adversarial.py`**: Pre-existing corruption fail-closed safety, complex configuration preservation (retaining user keybindings, custom profiles, and comments), rapid consecutive updates, and CLI return codes.
- **`tests/test_theme_adversarial.sh`**: End-to-end integration test runner validating all safety gates.
