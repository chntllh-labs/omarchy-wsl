"""Windows Terminal synchronization adapter.

Performs atomic, comment-preserving theme injection and profile mapping.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from omarchy_theme.atomic_io import atomic_update_text, safe_read_text
from omarchy_theme.jsonc import JsoncModifier, JsoncParseError
from omarchy_theme.models import ColorScheme

logger = logging.getLogger(__name__)


@dataclass
class AdapterResult:
    """Outcome of a theme synchronization operation."""

    success: bool
    target_path: Path
    message: str
    skipped: bool = False
    backup_path: Optional[Path] = None
    error: Optional[str] = None


MINIMAL_WT_TEMPLATE = """// Windows Terminal Configuration (Bootstrapped by Omarchy-WSL)
{
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "profiles": {
        "defaults": {},
        "list": []
    },
    "schemes": []
}
"""


def sync_windows_terminal(
    target_path: Path | str,
    theme: ColorScheme,
    target_profile: Optional[str] = "Omarchy",
    apply_to_defaults: bool = False,
    dry_run: bool = False,
    make_backup: bool = True,
) -> AdapterResult:
    """Synchronize a color scheme to a Windows Terminal settings.json file.

    The read, the JSONC edit and the write happen under one lock
    (atomic_update_text), so concurrent syncs (two Linux users, two distros,
    a second terminal) never lose each other's scheme or race the backups.
    """
    path = Path(target_path).resolve()
    wt_scheme = theme.to_windows_terminal_dict()

    def transform(current: Optional[str]) -> str:
        modifier = JsoncModifier(current if current is not None else MINIMAL_WT_TEMPLATE)
        modifier.upsert_windows_terminal_scheme(wt_scheme)
        modifier.set_profile_color_scheme(
            theme_name=theme.name,
            profile_name=target_profile,
            apply_to_defaults=apply_to_defaults,
        )
        return modifier.raw_text

    if dry_run:
        try:
            current = safe_read_text(path)[0] if path.exists() else None
            transform(current)
        except JsoncParseError as e:
            return AdapterResult(
                success=False,
                target_path=path,
                message=f"Pre-existing syntax error in host config at {e}. Aborting to prevent data corruption.",
                error=str(e),
            )
        except Exception as e:  # noqa: BLE001 - reported to the user
            return AdapterResult(False, path, f"Failed during surgical JSONC modification: {e}", error=str(e))
        verb = "initialize new" if not path.exists() else "update"
        return AdapterResult(True, path, f"[DRY-RUN] Would {verb} {path.name} with scheme '{theme.name}'")

    try:
        result = atomic_update_text(path, transform, encoding="utf-8", make_backup=make_backup)
    except JsoncParseError as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Pre-existing syntax error in host config at {e}. Aborting to prevent data corruption.",
            error=str(e),
        )
    except Exception as e:  # noqa: BLE001 - reported to the user
        return AdapterResult(False, path, f"Windows Terminal update failed: {e}", error=str(e))

    bak_file = path.with_name(f"{path.name}.bak")
    if not result.changed:
        return AdapterResult(True, path, f"Windows Terminal already uses '{theme.name}' ({path})", skipped=True)
    return AdapterResult(
        success=True,
        target_path=result.path,
        message=f"Successfully synchronized '{theme.name}' to Windows Terminal ({path})",
        backup_path=bak_file if bak_file.exists() else None,
    )
