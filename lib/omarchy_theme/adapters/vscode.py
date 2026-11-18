"""VS Code settings synchronization adapter.

Propagates terminal color customizations and active workbench theme atomically.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

from omarchy_theme.adapters.windows_terminal import AdapterResult
from omarchy_theme.atomic_io import atomic_update_text, safe_read_text
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
    """Synchronize a color scheme to VS Code settings.json (locked read-modify-write)."""
    path = Path(target_path).resolve()
    color_customs = theme.to_vscode_color_customizations()
    theme_name = theme.vscode_theme_name if sync_extension_theme else None

    def transform(current: Optional[str]) -> str:
        modifier = JsoncModifier(current if current is not None else "{\n}\n")
        modifier.upsert_vscode_color_customizations(color_customs, theme_name=theme_name)
        return modifier.raw_text

    if dry_run:
        try:
            current = safe_read_text(path)[0] if path.exists() else None
            transform(current)
        except JsoncParseError as e:
            return AdapterResult(
                success=False,
                target_path=path,
                message=f"Syntax error in existing VS Code settings at {e}. Aborting to avoid corruption.",
                error=str(e),
            )
        except Exception as e:  # noqa: BLE001 - reported to the user
            return AdapterResult(False, path, f"Failed modifying VS Code settings: {e}", error=str(e))
        return AdapterResult(True, path, f"[DRY-RUN] Verified valid VS Code update for '{theme.name}' on {path.name}")

    try:
        result = atomic_update_text(path, transform, encoding="utf-8", make_backup=make_backup)
    except JsoncParseError as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Syntax error in existing VS Code settings at {e}. Aborting to avoid corruption.",
            error=str(e),
        )
    except Exception as e:  # noqa: BLE001 - reported to the user
        return AdapterResult(False, path, f"VS Code settings update failed: {e}", error=str(e))

    bak_file = path.with_name(f"{path.name}.bak")
    if not result.changed:
        return AdapterResult(True, path, f"VS Code already uses '{theme.name}' ({path})", skipped=True)
    return AdapterResult(
        success=True,
        target_path=result.path,
        message=f"Successfully synchronized '{theme.name}' to VS Code ({path})",
        backup_path=bak_file if bak_file.exists() else None,
    )
