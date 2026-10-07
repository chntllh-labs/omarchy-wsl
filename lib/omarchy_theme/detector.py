"""Cross-OS environment detector and target locator.

Discovers Windows Terminal editions, VS Code instances, and Linux terminal
emulators across WSL2, native Windows, and pure Linux environments with graceful degradation.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


@dataclass
class TargetConfig:
    """A detected terminal or editor configuration target."""

    target_type: str  # 'windows_terminal', 'vscode', 'ghostty', 'alacritty', 'kitty', 'wezterm'
    edition: str      # 'stable', 'preview', 'canary', 'unpackaged', 'insiders', 'linux_native'
    path: Path
    exists: bool
    writable: bool
    metadata: Dict[str, str]


class HostDetector:
    """Detects host operating system, WSL state, and configuration file locations."""

    def __init__(self, override_local_appdata: Optional[Path] = None, override_appdata: Optional[Path] = None):
        self._override_local_appdata = override_local_appdata
        self._override_appdata = override_appdata
        self._is_wsl: Optional[bool] = None
        self._is_interop: Optional[bool] = None
        self._windows_user_profile: Optional[Path] = None
        self._local_appdata: Optional[Path] = override_local_appdata
        self._appdata: Optional[Path] = override_appdata

    # -------------------------------------------------------------------------
    # Environment Probing
    # -------------------------------------------------------------------------

    @property
    def is_windows(self) -> bool:
        return platform.system() == "Windows"

    @property
    def is_wsl(self) -> bool:
        if self._is_wsl is not None:
            return self._is_wsl

        if self.is_windows:
            self._is_wsl = False
            return False

        # Check WSL environment markers
        if "WSL_DISTRO_NAME" in os.environ or "WSL_INTEROP" in os.environ:
            self._is_wsl = True
            return True

        proc_version = Path("/proc/version")
        if proc_version.exists():
            try:
                content = proc_version.read_text().lower()
                if "microsoft" in content or "wsl" in content:
                    self._is_wsl = True
                    return True
            except OSError:
                pass

        self._is_wsl = False
        return False

    @property
    def is_interop_available(self) -> bool:
        """Check if WSL-to-Windows binary execution (WSLInterop) is operational."""
        if not self.is_wsl:
            return False

        if self._is_interop is not None:
            return self._is_interop

        # 1. Check binfmt_misc WSLInterop registration
        binfmt_path = Path("/proc/sys/fs/binfmt_misc/WSLInterop")
        if binfmt_path.exists():
            try:
                status = binfmt_path.read_text().strip().lower()
                if "disabled" in status:
                    self._is_interop = False
                    return False
            except OSError:
                pass

        # 2. Probe execution of cmd.exe
        cmd_bin = shutil.which("cmd.exe") or "/mnt/c/Windows/System32/cmd.exe"
        if os.path.exists(cmd_bin) or shutil.which("cmd.exe"):
            try:
                res = subprocess.run(
                    ["cmd.exe", "/c", "exit 0"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                )
                self._is_interop = (res.returncode == 0)
                return self._is_interop
            except (subprocess.SubprocessError, OSError):
                self._is_interop = False
                return False

        self._is_interop = False
        return False

    # -------------------------------------------------------------------------
    # Windows Directory Resolution
    # -------------------------------------------------------------------------

    def get_windows_local_appdata(self) -> Optional[Path]:
        """Resolve Windows %LOCALAPPDATA% directory."""
        if self._local_appdata:
            return self._local_appdata

        if self.is_windows:
            val = os.environ.get("LOCALAPPDATA")
            if val:
                self._local_appdata = Path(val)
                return self._local_appdata

        if self.is_wsl:
            # Try interop first
            if self.is_interop_available:
                try:
                    res = subprocess.run(
                        ["cmd.exe", "/c", "echo %LOCALAPPDATA%"],
                        capture_output=True,
                        text=True,
                        timeout=2.0,
                    )
                    win_path = res.stdout.strip()
                    if win_path and not win_path.startswith("%"):
                        wsl_path = self._windows_to_wsl_path(win_path)
                        if wsl_path and wsl_path.exists():
                            self._local_appdata = wsl_path
                            return self._local_appdata
                except Exception:
                    pass

            # Fallback: scan mounted DrvFS drives for user profile
            profile = self._discover_windows_profile_from_drvfs()
            if profile:
                candidate = profile / "AppData" / "Local"
                if candidate.exists():
                    self._local_appdata = candidate
                    return self._local_appdata

        return None

    def get_windows_appdata(self) -> Optional[Path]:
        """Resolve Windows %APPDATA% (Roaming) directory."""
        if self._appdata:
            return self._appdata

        if self.is_windows:
            val = os.environ.get("APPDATA")
            if val:
                self._appdata = Path(val)
                return self._appdata

        if self.is_wsl:
            if self.is_interop_available:
                try:
                    res = subprocess.run(
                        ["cmd.exe", "/c", "echo %APPDATA%"],
                        capture_output=True,
                        text=True,
                        timeout=2.0,
                    )
                    win_path = res.stdout.strip()
                    if win_path and not win_path.startswith("%"):
                        wsl_path = self._windows_to_wsl_path(win_path)
                        if wsl_path and wsl_path.exists():
                            self._appdata = wsl_path
                            return self._appdata
                except Exception:
                    pass

            profile = self._discover_windows_profile_from_drvfs()
            if profile:
                candidate = profile / "AppData" / "Roaming"
                if candidate.exists():
                    self._appdata = candidate
                    return self._appdata

        return None

    def _discover_windows_profile_from_drvfs(self) -> Optional[Path]:
        """Discover Windows user profile directly from DrvFS mounts when interop is unavailable."""
        if self._windows_user_profile:
            return self._windows_user_profile

        # Candidate mount prefixes: /mnt/c, /c, or parsed from /proc/mounts
        mount_roots: List[Path] = [Path("/mnt/c"), Path("/c")]

        # Read mounts to find any 9p or drvfs mounts
        proc_mounts = Path("/proc/mounts")
        if proc_mounts.exists():
            try:
                for line in proc_mounts.read_text().splitlines():
                    parts = line.split()
                    if len(parts) >= 3 and parts[2] in ("drvfs", "9p", "virtiofs"):
                        p = Path(parts[1])
                        if p not in mount_roots and (p / "Users").exists():
                            mount_roots.insert(0, p)
            except OSError:
                pass

        for root in mount_roots:
            users_dir = root / "Users"
            if not users_dir.is_dir():
                continue

            system_dirs: Set[str] = {"default", "default user", "public", "all users"}
            candidates: List[Path] = []

            try:
                for entry in users_dir.iterdir():
                    if entry.is_dir() and entry.name.lower() not in system_dirs:
                        if (entry / "AppData" / "Local").exists() or (entry / "NTUSER.DAT").exists():
                            candidates.append(entry)
            except OSError:
                continue

            if not candidates:
                continue

            # If current Linux user matches Windows username
            linux_user = os.environ.get("USER", "").lower()
            for cand in candidates:
                if cand.name.lower() == linux_user:
                    self._windows_user_profile = cand
                    return cand

            # Otherwise take the most recently modified profile
            try:
                candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
                self._windows_user_profile = candidates[0]
                return candidates[0]
            except OSError:
                if candidates:
                    self._windows_user_profile = candidates[0]
                    return candidates[0]

        return None

    def _windows_to_wsl_path(self, win_path: str) -> Optional[Path]:
        """Convert a Windows path like C:\\Users\\... to WSL Path."""
        clean = win_path.strip()
        if not clean:
            return None

        # Try wslpath CLI if available
        if shutil.which("wslpath"):
            try:
                res = subprocess.run(
                    ["wslpath", "-u", clean],
                    capture_output=True,
                    text=True,
                    timeout=1.5,
                )
                if res.returncode == 0 and res.stdout.strip():
                    return Path(res.stdout.strip())
            except Exception:
                pass

        # Fallback heuristic: C:\foo\bar -> /mnt/c/foo/bar
        if len(clean) >= 2 and clean[1] == ":":
            drive = clean[0].lower()
            rest = clean[2:].replace("\\", "/").lstrip("/")
            # Check standard /mnt/c or /c
            for prefix in [Path(f"/mnt/{drive}"), Path(f"/{drive}")]:
                cand = prefix / rest
                if cand.parent.exists() or cand.exists():
                    return cand
            return Path(f"/mnt/{drive}") / rest

        return None

    # -------------------------------------------------------------------------
    # Target Discovery
    # -------------------------------------------------------------------------

    def find_windows_terminal_targets(self) -> List[TargetConfig]:
        """Locate all Windows Terminal settings.json files across variations."""
        targets: List[TargetConfig] = []
        local_appdata = self.get_windows_local_appdata()
        if not local_appdata or not local_appdata.exists():
            return targets

        packages_dir = local_appdata / "Packages"

        # 1. Stable MSIX (Microsoft.WindowsTerminal_8wekyb3d8bbwe)
        # Scan packages_dir for matching prefix to tolerate package version/family shifts
        if packages_dir.is_dir():
            try:
                for pkg in packages_dir.iterdir():
                    name = pkg.name
                    if name.startswith("Microsoft.WindowsTerminal_") and not name.startswith("Microsoft.WindowsTerminalPreview_") and not name.startswith("Microsoft.WindowsTerminalCanary_"):
                        settings_path = pkg / "LocalState" / "settings.json"
                        targets.append(
                            TargetConfig(
                                target_type="windows_terminal",
                                edition="stable",
                                path=settings_path,
                                exists=settings_path.exists(),
                                writable=os.access(settings_path.parent, os.W_OK) if settings_path.parent.exists() else False,
                                metadata={"package": name},
                            )
                        )
                    elif name.startswith("Microsoft.WindowsTerminalPreview_"):
                        settings_path = pkg / "LocalState" / "settings.json"
                        targets.append(
                            TargetConfig(
                                target_type="windows_terminal",
                                edition="preview",
                                path=settings_path,
                                exists=settings_path.exists(),
                                writable=os.access(settings_path.parent, os.W_OK) if settings_path.parent.exists() else False,
                                metadata={"package": name},
                            )
                        )
                    elif name.startswith("Microsoft.WindowsTerminalCanary_"):
                        settings_path = pkg / "LocalState" / "settings.json"
                        targets.append(
                            TargetConfig(
                                target_type="windows_terminal",
                                edition="canary",
                                path=settings_path,
                                exists=settings_path.exists(),
                                writable=os.access(settings_path.parent, os.W_OK) if settings_path.parent.exists() else False,
                                metadata={"package": name},
                            )
                        )
            except OSError:
                pass

        # 2. Unpackaged / Default (%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json)
        unpackaged_path = local_appdata / "Microsoft" / "Windows Terminal" / "settings.json"
        if unpackaged_path.parent.exists() or unpackaged_path.exists():
            targets.append(
                TargetConfig(
                    target_type="windows_terminal",
                    edition="unpackaged",
                    path=unpackaged_path,
                    exists=unpackaged_path.exists(),
                    writable=os.access(unpackaged_path.parent, os.W_OK) if unpackaged_path.parent.exists() else False,
                    metadata={"unpackaged": "true"},
                )
            )

        return targets

    def find_vscode_targets(self) -> List[TargetConfig]:
        """Locate all VS Code settings.json files (Windows Host & WSL server)."""
        targets: List[TargetConfig] = []
        appdata = self.get_windows_appdata()

        if appdata and appdata.exists():
            # 1. VS Code Stable on Windows
            stable_path = appdata / "Code" / "User" / "settings.json"
            if stable_path.parent.exists() or stable_path.exists():
                targets.append(
                    TargetConfig(
                        target_type="vscode",
                        edition="stable",
                        path=stable_path,
                        exists=stable_path.exists(),
                        writable=os.access(stable_path.parent, os.W_OK) if stable_path.parent.exists() else False,
                        metadata={"scope": "windows_host"},
                    )
                )

            # 2. VS Code Insiders on Windows
            insiders_path = appdata / "Code - Insiders" / "User" / "settings.json"
            if insiders_path.parent.exists() or insiders_path.exists():
                targets.append(
                    TargetConfig(
                        target_type="vscode",
                        edition="insiders",
                        path=insiders_path,
                        exists=insiders_path.exists(),
                        writable=os.access(insiders_path.parent, os.W_OK) if insiders_path.parent.exists() else False,
                        metadata={"scope": "windows_host"},
                    )
                )

            # 3. VSCodium
            codium_path = appdata / "VSCodium" / "User" / "settings.json"
            if codium_path.parent.exists() or codium_path.exists():
                targets.append(
                    TargetConfig(
                        target_type="vscode",
                        edition="codium",
                        path=codium_path,
                        exists=codium_path.exists(),
                        writable=os.access(codium_path.parent, os.W_OK) if codium_path.parent.exists() else False,
                        metadata={"scope": "windows_host"},
                    )
                )

        # 4. WSL VS Code Server machine settings
        home = Path.home()
        server_path = home / ".vscode-server" / "data" / "Machine" / "settings.json"
        if server_path.parent.exists() or server_path.exists():
            targets.append(
                TargetConfig(
                    target_type="vscode",
                    edition="server_machine",
                    path=server_path,
                    exists=server_path.exists(),
                    writable=os.access(server_path.parent, os.W_OK) if server_path.parent.exists() else False,
                    metadata={"scope": "wsl_machine"},
                )
            )

        return targets

    def find_linux_terminal_targets(self) -> List[TargetConfig]:
        """Locate native Linux terminal emulator configs in user home."""
        targets: List[TargetConfig] = []
        home = Path.home()

        # Ghostty
        ghostty_cfg = home / ".config" / "ghostty" / "config"
        targets.append(
            TargetConfig(
                target_type="ghostty",
                edition="linux_native",
                path=ghostty_cfg,
                exists=ghostty_cfg.exists(),
                writable=os.access(ghostty_cfg.parent, os.W_OK) if ghostty_cfg.parent.exists() else True,
                metadata={},
            )
        )

        # Alacritty
        alacritty_toml = home / ".config" / "alacritty" / "alacritty.toml"
        targets.append(
            TargetConfig(
                target_type="alacritty",
                edition="linux_native",
                path=alacritty_toml,
                exists=alacritty_toml.exists(),
                writable=os.access(alacritty_toml.parent, os.W_OK) if alacritty_toml.parent.exists() else True,
                metadata={},
            )
        )

        # Kitty
        kitty_cfg = home / ".config" / "kitty" / "current-theme.conf"
        targets.append(
            TargetConfig(
                target_type="kitty",
                edition="linux_native",
                path=kitty_cfg,
                exists=kitty_cfg.exists(),
                writable=os.access(kitty_cfg.parent, os.W_OK) if kitty_cfg.parent.exists() else True,
                metadata={},
            )
        )

        # WezTerm
        wezterm_lua = home / ".config" / "wezterm" / "wezterm.lua"
        targets.append(
            TargetConfig(
                target_type="wezterm",
                edition="linux_native",
                path=wezterm_lua,
                exists=wezterm_lua.exists(),
                writable=os.access(wezterm_lua.parent, os.W_OK) if wezterm_lua.parent.exists() else True,
                metadata={},
            )
        )

        return targets
