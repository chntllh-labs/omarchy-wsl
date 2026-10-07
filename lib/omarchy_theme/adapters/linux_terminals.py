"""Omarchy Linux native terminal adapters (Ghostty, Alacritty, Kitty, WezTerm)."""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import List, Optional

from omarchy_theme.adapters.windows_terminal import AdapterResult
from omarchy_theme.atomic_io import atomic_write_text, safe_read_text
from omarchy_theme.models import ColorScheme

logger = logging.getLogger(__name__)


def sync_ghostty(theme: ColorScheme, config_path: Optional[Path] = None, dry_run: bool = False) -> AdapterResult:
    """Sync theme to Ghostty terminal configuration."""
    path = config_path or (Path.home() / ".config" / "ghostty" / "config")
    ghostty_content = theme.to_ghostty_config()

    if not path.parent.exists():
        path.parent.mkdir(parents=True, exist_ok=True)

    if dry_run:
        return AdapterResult(True, path, f"[DRY-RUN] Would update Ghostty theme to '{theme.name}'")

    try:
        # If file exists, update or append theme block
        if path.exists():
            current_text, _ = safe_read_text(path)
            # Remove existing Omarchy theme block if present
            cleaned = re.sub(r"# Omarchy theme:.*?(?=\n\S|\Z)", "", current_text, flags=re.DOTALL)
            new_text = cleaned.rstrip() + "\n\n" + ghostty_content
        else:
            new_text = ghostty_content

        written = atomic_write_text(path, new_text)
        return AdapterResult(True, written, f"Updated Ghostty theme to '{theme.name}'")
    except Exception as e:
        return AdapterResult(False, path, f"Failed updating Ghostty: {e}", error=str(e))


def sync_kitty(theme: ColorScheme, config_path: Optional[Path] = None, dry_run: bool = False) -> AdapterResult:
    """Sync theme to Kitty terminal configuration."""
    kitty_dir = config_path.parent if config_path else (Path.home() / ".config" / "kitty")
    theme_file = kitty_dir / "current-theme.conf"
    main_conf = kitty_dir / "kitty.conf"

    if dry_run:
        return AdapterResult(True, theme_file, f"[DRY-RUN] Would update Kitty theme to '{theme.name}'")

    try:
        kitty_dir.mkdir(parents=True, exist_ok=True)
        content = theme.to_kitty_config()
        atomic_write_text(theme_file, content)

        # Ensure kitty.conf includes current-theme.conf
        include_line = "include current-theme.conf"
        if main_conf.exists():
            main_text, _ = safe_read_text(main_conf)
            if include_line not in main_text:
                atomic_write_text(main_conf, main_text.rstrip() + f"\n\n{include_line}\n")
        else:
            atomic_write_text(main_conf, f"{include_line}\n")

        return AdapterResult(True, theme_file, f"Updated Kitty theme to '{theme.name}'")
    except Exception as e:
        return AdapterResult(False, theme_file, f"Failed updating Kitty: {e}", error=str(e))


def sync_alacritty(theme: ColorScheme, config_path: Optional[Path] = None, dry_run: bool = False) -> AdapterResult:
    """Sync theme to Alacritty configuration."""
    path = config_path or (Path.home() / ".config" / "alacritty" / "alacritty.toml")
    alacritty_data = theme.to_alacritty_dict()

    if dry_run:
        return AdapterResult(True, path, f"[DRY-RUN] Would update Alacritty theme to '{theme.name}'")

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Format TOML colors block
        c = alacritty_data["colors"]
        lines = [
            f"# Omarchy theme: {theme.name}",
            "[colors.primary]",
            f'background = "{c["primary"]["background"]}"',
            f'foreground = "{c["primary"]["foreground"]}"',
            "",
            "[colors.cursor]",
            f'cursor = "{c["cursor"]["cursor"]}"',
            f'text = "{c["cursor"]["text"]}"',
            "",
            "[colors.selection]",
            f'background = "{c["selection"]["background"]}"',
            f'text = "{c["selection"]["text"]}"',
            "",
            "[colors.normal]",
            f'black = "{c["normal"]["black"]}"',
            f'red = "{c["normal"]["red"]}"',
            f'green = "{c["normal"]["green"]}"',
            f'yellow = "{c["normal"]["yellow"]}"',
            f'blue = "{c["normal"]["blue"]}"',
            f'magenta = "{c["normal"]["magenta"]}"',
            f'cyan = "{c["normal"]["cyan"]}"',
            f'white = "{c["normal"]["white"]}"',
            "",
            "[colors.bright]",
            f'black = "{c["bright"]["black"]}"',
            f'red = "{c["bright"]["red"]}"',
            f'green = "{c["bright"]["green"]}"',
            f'yellow = "{c["bright"]["yellow"]}"',
            f'blue = "{c["bright"]["blue"]}"',
            f'magenta = "{c["bright"]["magenta"]}"',
            f'cyan = "{c["bright"]["cyan"]}"',
            f'white = "{c["bright"]["white"]}"',
        ]
        toml_block = "\n".join(lines) + "\n"

        if path.exists():
            existing, _ = safe_read_text(path)
            # Remove any existing [colors.*] sections
            cleaned = re.sub(r"# Omarchy theme:.*?(?=\n\[(?!(colors))\w+|\Z)", "", existing, flags=re.DOTALL)
            new_text = cleaned.rstrip() + "\n\n" + toml_block
        else:
            new_text = toml_block

        written = atomic_write_text(path, new_text)
        return AdapterResult(True, written, f"Updated Alacritty theme to '{theme.name}'")
    except Exception as e:
        return AdapterResult(False, path, f"Failed updating Alacritty: {e}", error=str(e))


def sync_all_linux_terminals(theme: ColorScheme, dry_run: bool = False) -> List[AdapterResult]:
    """Sync theme across all supported Linux terminal emulators."""
    results: List[AdapterResult] = []
    results.append(sync_ghostty(theme, dry_run=dry_run))
    results.append(sync_kitty(theme, dry_run=dry_run))
    results.append(sync_alacritty(theme, dry_run=dry_run))
    return results
