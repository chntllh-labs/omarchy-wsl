"""Windows Terminal synchronization adapter.

Performs atomic, comment-preserving theme injection and profile mapping.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from omarchy_theme.atomic_io import atomic_write_text, safe_read_text
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
    """Synchronize a color scheme to a Windows Terminal settings.json file."""
    path = Path(target_path).resolve()

    if not path.exists():
        # Target doesn't exist yet; initialize minimal valid template
        if dry_run:
            return AdapterResult(
                success=True,
                target_path=path,
                message=f"[DRY-RUN] Would initialize new settings.json with scheme '{theme.name}'",
            )
        try:
            content = MINIMAL_WT_TEMPLATE
            encoding = "utf-8"
        except Exception as e:
            return AdapterResult(
                success=False,
                target_path=path,
                message=f"Failed to initialize settings template: {e}",
                error=str(e),
            )
    else:
        # Read existing file safely
        try:
            content, encoding = safe_read_text(path)
        except Exception as e:
            return AdapterResult(
                success=False,
                target_path=path,
                message=f"Failed to read existing settings.json: {e}",
                error=str(e),
            )

    # Parse and modify surgically
    try:
        modifier = JsoncModifier(content)
    except JsoncParseError as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Pre-existing syntax error in host config at {e}. Aborting to prevent data corruption.",
            error=str(e),
        )

    wt_scheme = theme.to_windows_terminal_dict()
    try:
        # 1. Upsert scheme in schemes array
        modifier.upsert_windows_terminal_scheme(wt_scheme)

        # 2. Update profile or defaults
        modifier.set_profile_color_scheme(
            theme_name=theme.name,
            profile_name=target_profile,
            apply_to_defaults=apply_to_defaults,
        )
    except Exception as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Failed during surgical JSONC modification: {e}",
            error=str(e),
        )

    final_text = modifier.raw_text

    if dry_run:
        return AdapterResult(
            success=True,
            target_path=path,
            message=f"[DRY-RUN] Verified valid update for '{theme.name}' on {path.name}",
        )

    # 3. Write atomically to disk
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
            message=f"Successfully synchronized '{theme.name}' to Windows Terminal ({path})",
            backup_path=bak_file if bak_file.exists() else None,
        )
    except Exception as e:
        return AdapterResult(
            success=False,
            target_path=path,
            message=f"Atomic write failed: {e}",
            error=str(e),
        )
