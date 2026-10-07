#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: First-Boot Interactive Profile Hook (/etc/profile.d/)
# ==============================================================================
# Guarantees seamless transition from root to UID 1000 user even when imported
# manually via 'wsl --import', where WSL's built-in 'wsl-distribution.conf'
# OOBE launcher is bypassed.
#
# BEHAVIOR:
# 1. Triggers only for root login shells when OOBE has not yet completed.
# 2. Executes OOBE provisioning engine (/usr/lib/omarchy-wsl/oobe.sh).
# 3. Upon successful completion, immediately transitions interactive root shells
#    into the newly provisioned user's login shell via runuser/exec.
# 4. Completely inert on all subsequent launches or explicit root sessions.
# ==============================================================================

# Fast-path: Only execute for root when OOBE sentinel is absent
if [[ "${EUID:-$(id -u)}" -eq 0 && ! -f /var/lib/omarchy/oobe_completed ]]; then
    # Locate OOBE script across standard distribution paths
    OOBE_BIN=""
    for candidate in /usr/lib/omarchy-wsl/oobe.sh /etc/oobe.sh /usr/libexec/omarchy/oobe.sh; do
        if [[ -x "$candidate" ]]; then
            OOBE_BIN="$candidate"
            break
        fi
    done

    if [[ -n "$OOBE_BIN" ]]; then
        # Execute OOBE provisioning
        "$OOBE_BIN"

        # If interactive TTY session, immediately transition into provisioned user
        if [[ -t 0 && -t 1 && -f /var/lib/omarchy/oobe_completed ]]; then
            PROV_USER=$(grep -E '^PROVISIONED_USER=' /var/lib/omarchy/oobe_completed 2>/dev/null | cut -d= -f2 || true)
            if [[ -n "$PROV_USER" ]] && id -u "$PROV_USER" >/dev/null 2>&1; then
                printf "\n[omarchy-wsl] Transitioning interactive session to '%s'...\n" "$PROV_USER"
                exec runuser -u "$PROV_USER" -- /bin/bash -l
            fi
        fi
    fi
fi
