"""VS Code settings synchronization adapter.

Propagates terminal color customizations and active workbench theme atomically.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

from omarchy_theme.adapters.windows_terminal import AdapterResult
from omarchy_theme.atomic_io import atomic_write_text, safe_read_text
from omarchy_theme.jsonc import JsoncModifier, JsoncParseError
from omarchy_theme.models import ColorScheme

logger = logging.getLogger(__name__)


def sync_vscode(
    target_path: Path | str,
    theme: ColorScheme,
    sync_extension_theme: bool = True,
    dry_run: bool = False,
    make_backup: bool = True,
) -> AdapterResult:
    """Synchronize a color scheme to VS Code settings.json."""
    path = Path(target_path).resolve()

    if not path.exists():
        content = "{\n}\n"
    else:
        try:
            content, _ = safe_read_text(path)
        except Exception as e:
            return AdapterResult(
                success=False,
                target_path=path,
                message=f"Failed to read existing VS Code settings.json: {e}",
                error=str(e),
            )

    try:
        modifier = JsoncModifier(content)
    except JsoncParseError as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Syntax error in existing VS Code settings at {e}. Aborting to avoid corruption.",
            error=str(e),
        )

    color_customs = theme.to_vscode_color_customizations()
    theme_name = theme.vscode_theme_name if sync_extension_theme else None

    try:
        modifier.upsert_vscode_color_customizations(color_customs, theme_name=theme_name)
    except Exception as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Failed modifying VS Code settings: {e}",
            error=str(e),
        )

    final_text = modifier.raw_text

    if dry_run:
        return AdapterResult(
            success=True,
            target_path=path,
            message=f"[DRY-RUN] Verified valid VS Code update for '{theme.name}' on {path.name}",
        )

    try:
        written_path = atomic_write_text(
            target_path=path,
            content=final_text,
            encoding="utf-8",
            make_backup=make_backup,
        )
        bak_file = path.with_name(f"{path.name}.bak")
        return AdapterResult(
            success=True,
            target_path=written_path,
            message=f"Successfully synchronized '{theme.name}' to VS Code ({path})",
            backup_path=bak_file if bak_file.exists() else None,
        )
    except Exception as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Atomic write to VS Code config failed: {e}",
            error=str(e),
        )
