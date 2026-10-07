#!/usr/bin/env bash
# ==============================================================================
# Omarchy-WSL: Dynamic Out-Of-Box Experience (OOBE) & User Provisioning Engine
# ==============================================================================
# Adversarially hardened, completely neutral distribution OOBE engine.
# Designed for dual-architecture (ARM64 Snapdragon Oryon & x86_64) on ANY Windows host.
#
# GUARANTEES & ADVERSARIAL HARDENING:
# 1. Zero Hardcoding: Dynamically detects and provisions the real Windows host user.
# 2. Resilient %USERNAME% Interop: Recovers host username even if appendWindowsPath=false,
#    interop is restricted, custom mount points are used, or special characters exist.
# 3. Robust POSIX Sanitization: Handles spaces (e.g. 'John Doe'), uppercase, Unicode/diacritics
#    (e.g. 'Müller', 'José'), symbols, leading digits, and overlong usernames.
# 4. Headless & Automated Invocation: Never hangs or crashes on non-TTY, CI, or 'wsl --exec'.
# 5. Collision Resilience: Reconciles pre-existing UID 1000 accounts (e.g. ALARM 'alarm')
#    and safeguards reserved Linux system accounts (< UID 1000).
# 6. Atomic wsl.conf Updater: Safely injects [user] default without corrupting INI syntax.
# 7. Sudoers Integrity: Validates drop-ins via visudo; guarantees administrative safety.
# 8. Offline Systemd Lingering: Configures lingering directly on disk and via D-Bus.
# 9. Single-Root ~/hermes Scaffolding: Provisions workspace, worktrees, and scratch.
# 10. Strict Idempotency: Instant exit 0 on subsequent runs without repeated mutations.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration & Constants
# ------------------------------------------------------------------------------
readonly OOBE_VERSION="1.0.0"
readonly TARGET_UID=1000
SENTINEL_DIR="${OMARCHY_SENTINEL_DIR:-/var/lib/omarchy}"
SENTINEL_FILE="${SENTINEL_DIR}/oobe_completed"
USER_CONF_FILE="${OMARCHY_USER_CONF:-/etc/omarchy-user.conf}"
WSL_CONF_FILE="${OMARCHY_WSL_CONF:-/etc/wsl.conf}"
SUDOERS_DIR="${OMARCHY_SUDOERS_DIR:-/etc/sudoers.d}"
LINGER_DIR="${OMARCHY_LINGER_DIR:-/var/lib/systemd/linger}"
readonly FALLBACK_DEFAULT_USER="omarchy"
readonly DEFAULT_THEME="Tokyo Night"

# Default secondary groups (filtered dynamically by system availability)
readonly CANDIDATE_GROUPS=(
    wheel
    docker
    audio
    video
    render
    kvm
    storage
    input
    optical
    users
    adm
    systemd-journal
)

# Hermes workspace scaffolding subdirectories
readonly HERMES_DIRS=(
    workspace
    worktrees
    scratch
)

# Temporary files tracking for signal cleanup
TMP_FILES=()

# shellcheck disable=SC2329
cleanup() {
    local exit_code=$?
    if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
        for f in "${TMP_FILES[@]}"; do
            if [[ -f "$f" ]]; then
                rm -f "$f" 2>/dev/null || true
            fi
        done
    fi
    exit "$exit_code"
}

# ------------------------------------------------------------------------------
# Logging & Terminal Output
# ------------------------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET="\033[0m"
    readonly C_BOLD="\033[1m"
    readonly C_CYAN="\033[36m"
    readonly C_GREEN="\033[32m"
    readonly C_YELLOW="\033[33m"
    readonly C_RED="\033[31m"
else
    readonly C_RESET=""
    readonly C_BOLD=""
    readonly C_CYAN=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_RED=""
fi

log_info()    { printf "${C_CYAN}[omarchy-oobe]${C_RESET} %s\n" "$*"; }
log_step()    { printf "${C_CYAN}[*]${C_RESET} %s\n" "$*"; }
log_success() { printf "${C_GREEN}[+]${C_RESET} %s\n" "$*"; }
log_warn()    { printf "${C_YELLOW}[!] WARNING:${C_RESET} %s\n" "$*" >&2; }
log_err()     { printf "${C_RED}[-] ERROR:${C_RESET} %s\n" "$*" >&2; }
die()         { log_err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# 1. Host %USERNAME% Detection Engine
# ------------------------------------------------------------------------------
# Probes multiple interop and filesystem vectors to discover the Windows host
# username, designed to survive appendWindowsPath=false, non-standard DrvFs mounts,
# and disabled interop.
detect_windows_username() {
    local detected=""
    local candidate=""

    # Vector 1: Explicit environment overrides
    if [[ -n "${OMARCHY_USER:-}" ]]; then
        printf '%s' "$OMARCHY_USER"
        return 0
    fi
    if [[ -n "${TARGET_USER:-}" ]]; then
        printf '%s' "$TARGET_USER"
        return 0
    fi

    # Vector 2: User configuration file override
    if [[ -f "$USER_CONF_FILE" ]]; then
        candidate=$(grep -E '^[[:space:]]*(DEFAULT_USER|TARGET_USER|OMARCHY_USER)[[:space:]]*=' "$USER_CONF_FILE" 2>/dev/null \
            | head -n1 | cut -d= -f2 | tr -d ' "' | tr -d "'" || true)
        if [[ -n "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    fi

    # Vector 3: Kernel command line (e.g. omarchy.user=alice passed during boot)
    if [[ -r /proc/cmdline ]]; then
        candidate=$(grep -oE 'omarchy\.user=[^ ]+' /proc/cmdline 2>/dev/null | cut -d= -f2 | head -n1 || true)
        if [[ -n "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    fi

    # Vector 4: WSLENV passed environment variables
    if [[ -n "${WSLENV:-}" ]]; then
        if [[ -n "${USERNAME:-}" ]]; then
            printf '%s' "$USERNAME"
            return 0
        fi
        if [[ -n "${USER:-}" ]] && [[ "$USER" != "root" ]]; then
            printf '%s' "$USER"
            return 0
        fi
    fi

    # Vector 5: Windows cmd.exe interop execution
    # Must probe explicit paths because appendWindowsPath=false removes System32 from PATH
    local cmd_candidates=()
    if command -v cmd.exe >/dev/null 2>&1; then
        cmd_candidates+=("$(command -v cmd.exe)")
    fi
    cmd_candidates+=(
        "/mnt/c/Windows/System32/cmd.exe"
        "/c/Windows/System32/cmd.exe"
    )

    # Dynamically discover all DrvFs / 9p mounts from /proc/mounts
    if [[ -r /proc/mounts ]]; then
        while read -r _ mnt fstype _; do
            if [[ "$fstype" == "9p" || "$fstype" == "drvfs" ]]; then
                if [[ -f "${mnt}/Windows/System32/cmd.exe" ]]; then
                    cmd_candidates+=("${mnt}/Windows/System32/cmd.exe")
                fi
            fi
        done < /proc/mounts 2>/dev/null || true
    fi

    for cmd_bin in "${cmd_candidates[@]}"; do
        if [[ -f "$cmd_bin" ]] || command -v "$cmd_bin" >/dev/null 2>&1; then
            # Run with strict timeout; strip carriage returns immediately
            detected=$(timeout 3 "$cmd_bin" /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || true)
            # cmd.exe echoes literal "%USERNAME%" if variable is unset or interop failed
            if [[ -n "$detected" && "$detected" != "%USERNAME%" ]]; then
                printf '%s' "$detected"
                return 0
            fi
        fi
    done

    # Vector 6: Windows powershell.exe interop execution
    local ps_candidates=()
    if command -v powershell.exe >/dev/null 2>&1; then
        ps_candidates+=("$(command -v powershell.exe)")
    fi
    ps_candidates+=(
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    )
    if [[ -r /proc/mounts ]]; then
        while read -r _ mnt fstype _; do
            if [[ "$fstype" == "9p" || "$fstype" == "drvfs" ]]; then
                if [[ -f "${mnt}/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
                    ps_candidates+=("${mnt}/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
                fi
            fi
        done < /proc/mounts 2>/dev/null || true
    fi

    for ps_bin in "${ps_candidates[@]}"; do
        if [[ -f "$ps_bin" ]] || command -v "$ps_bin" >/dev/null 2>&1; then
            detected=$(timeout 4 "$ps_bin" -NoProfile -NonInteractive -Command "Write-Output \$env:USERNAME" 2>/dev/null | tr -d '\r\n' || true)
            if [[ -n "$detected" ]]; then
                printf '%s' "$detected"
                return 0
            fi
        fi
    done

    # Vector 7: Filesystem inspection of DrvFs Users directory
    # Fallback when interop execution is blocked (e.g. binfmt disabled)
    local user_dirs=("/mnt/c/Users" "/c/Users")
    if [[ -r /proc/mounts ]]; then
        while read -r _ mnt fstype _; do
            if [[ "$fstype" == "9p" || "$fstype" == "drvfs" ]]; then
                if [[ -d "${mnt}/Users" ]]; then
                    user_dirs+=("${mnt}/Users")
                fi
            fi
        done < /proc/mounts 2>/dev/null || true
    fi

    for udir in "${user_dirs[@]}"; do
        if [[ -d "$udir" ]]; then
            local ulist=()
            for d in "$udir"/*; do
                [[ -d "$d" ]] || continue
                local bname
                bname=$(basename "$d")
                case "$bname" in
                    Default|"Default User"|Public|"All Users"|Administrator|desktop.ini|\.*)
                        continue ;;
                    *)
                        ulist+=("$bname") ;;
                esac
            done
            if [[ ${#ulist[@]} -ge 1 ]]; then
                printf '%s' "${ulist[0]}"
                return 0
            fi
        fi
    done

    # Vector 8: Deterministic fallback
    printf '%s' "$FALLBACK_DEFAULT_USER"
    return 0
}

# ------------------------------------------------------------------------------
# 2. Username Sanitization & Normalization Engine
# ------------------------------------------------------------------------------
# Transforms arbitrary Windows usernames (spaces, dots, uppercase, diacritics, CJK)
# into strictly valid POSIX compliant Linux usernames (^[a-z_][a-z0-9_-]{0,31}$).
sanitize_username() {
    local raw="$1"
    local clean translit

    # 1. Strip carriage returns, newlines, and surrounding whitespace
    clean=$(printf '%s' "$raw" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # 2. Lowercase conversion
    clean=$(printf '%s' "$clean" | tr '[:upper:]' '[:lower:]')

    # 3. Transliterate Unicode/accents if iconv is available (e.g. François -> francois)
    if command -v iconv >/dev/null 2>&1; then
        translit=$(printf '%s' "$clean" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || true)
        if [[ -n "$translit" ]]; then
            clean="$translit"
        fi
    fi

    # 4. Replace illegal characters (anything not a-z, 0-9, _, -) with underscores
    clean=$(printf '%s' "$clean" | sed -E 's/[^a-z0-9_-]/_/g')

    # 5. Collapse multiple underscores and hyphens into single underscore
    clean=$(printf '%s' "$clean" | sed -E 's/[_-]+/_/g')

    # 6. Ensure username does not begin with digit or hyphen (POSIX requires [a-z_])
    case "$clean" in
        [0-9]*) clean="u_${clean}" ;;
        -*)     clean="_${clean#-}" ;;
    esac

    # 7. Strip trailing underscores
    clean=$(printf '%s' "$clean" | sed -E 's/_+$//')

    # 8. Truncate to 31 characters (POSIX UT_NAMESIZE limit - 1)
    clean=$(printf '%s' "$clean" | cut -c 1-31)

    # 9. Verify POSIX regex: ^[a-z_][a-z0-9_-]{0,31}$
    if [[ ! "$clean" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [[ -z "$clean" ]]; then
        clean="$FALLBACK_DEFAULT_USER"
    fi

    printf '%s' "$clean"
}

# ------------------------------------------------------------------------------
# 3. System UID Collision & Reservation Guard
# ------------------------------------------------------------------------------
# Ensures the candidate username does not collide with reserved system accounts
# (UID < 1000) such as root, daemon, bin, sys, sshd, dbus, nobody.
resolve_name_collision() {
    local candidate="$1"
    local interactive="$2"
    local existing_uid

    while true; do
        existing_uid=$(id -u "$candidate" 2>/dev/null || true)

        if [[ -z "$existing_uid" ]]; then
            # No account exists with this name; free to use
            printf '%s' "$candidate"
            return 0
        fi

        if [[ "$existing_uid" -eq "$TARGET_UID" ]]; then
            # Name already belongs to UID 1000; valid target
            printf '%s' "$candidate"
            return 0
        fi

        # Collision with system account (UID < 1000) or other UID
        if [[ "$interactive" == "true" ]]; then
            log_warn "Username '$candidate' is reserved by a system account (UID $existing_uid)."
            read -r -p "Please enter an alternative UNIX username: " candidate
            candidate=$(sanitize_username "$candidate")
        else
            # Automated resolution: prefix with 'u_'
            candidate="u_${candidate}"
            if [[ ${#candidate} -gt 31 ]]; then
                candidate=$(printf '%s' "$candidate" | cut -c 1-31)
            fi
            # If u_ prefix also collides, fallback to neutral user1000
            if id -u "$candidate" >/dev/null 2>&1; then
                candidate="user${TARGET_UID}"
            fi
            printf '%s' "$candidate"
            return 0
        fi
    done
}

# ------------------------------------------------------------------------------
# 4. UID 1000 User Account Reconciler
# ------------------------------------------------------------------------------
# Guarantees the chosen username is provisioned with UID 1000.
# Reconciles pre-existing UID 1000 accounts (e.g. 'alarm' on Arch Linux ARM rootfs)
# by cleanly renaming user, primary group, and home directory.
provision_user_account() {
    local target_user="$1"
    local existing_1000

    existing_1000=$(getent passwd "$TARGET_UID" | cut -d: -f1 || true)

    if [[ -n "$existing_1000" ]]; then
        if [[ "$existing_1000" == "$target_user" ]]; then
            log_info "User '$target_user' already exists with UID $TARGET_UID."
            return 0
        fi

        log_step "Reconciling pre-existing UID $TARGET_UID account ('$existing_1000' -> '$target_user')..."

        # Terminate any lingering processes owned by old UID 1000
        pkill -u "$TARGET_UID" 2>/dev/null || true

        # Attempt clean rename of user and group
        if usermod -l "$target_user" "$existing_1000" 2>/dev/null; then
            if getent group "$existing_1000" >/dev/null 2>&1; then
                groupmod -n "$target_user" "$existing_1000" 2>/dev/null || true
            fi
            local old_home new_home
            old_home=$(getent passwd "$target_user" | cut -d: -f6)
            new_home="/home/$target_user"
            if [[ -d "$old_home" && "$old_home" != "$new_home" ]]; then
                usermod -d "$new_home" -m "$target_user" 2>/dev/null || mv "$old_home" "$new_home" 2>/dev/null || true
            else
                mkdir -p "$new_home"
                usermod -d "$new_home" "$target_user" 2>/dev/null || true
            fi
            chown -R "${target_user}:${target_user}" "$new_home" 2>/dev/null || true
            log_success "Successfully reconciled UID $TARGET_UID to '$target_user'."
            return 0
        else
            log_warn "usermod rename failed; removing stock '$existing_1000' and recreating..."
            pkill -9 -u "$TARGET_UID" 2>/dev/null || true
            userdel -f "$existing_1000" 2>/dev/null || true
            groupdel "$existing_1000" 2>/dev/null || true
        fi
    fi

    # Create primary group if needed
    if ! getent group "$target_user" >/dev/null 2>&1; then
        groupadd -g "$TARGET_UID" "$target_user" 2>/dev/null || groupadd "$target_user" 2>/dev/null || true
    fi

    local user_gid
    user_gid=$(id -g "$target_user" 2>/dev/null || getent group "$target_user" | cut -d: -f3 || echo "$TARGET_UID")

    log_step "Creating user '$target_user' (UID $TARGET_UID)..."
    useradd -m -u "$TARGET_UID" -g "$user_gid" -s /bin/bash "$target_user" 2>/dev/null || \
        useradd -m -u "$TARGET_UID" -s /bin/bash "$target_user"

    log_success "Created user '$target_user' with UID $TARGET_UID."
}

# ------------------------------------------------------------------------------
# 5. Dynamic Secondary Group Assignment
# ------------------------------------------------------------------------------
# Assigns secondary groups only if they exist on the target system, preventing
# failures on minimal rootfs installations.
assign_secondary_groups() {
    local target_user="$1"

    for grp in "${CANDIDATE_GROUPS[@]}"; do
        if getent group "$grp" >/dev/null 2>&1; then
            usermod -aG "$grp" "$target_user" 2>/dev/null || true
        fi
    done
}

# ------------------------------------------------------------------------------
# 6. Sudoers Drop-in Configuration
# ------------------------------------------------------------------------------
# Writes a secure sudoers rule with visudo validation to prevent administrative lockout.
configure_sudoers() {
    local target_user="$1"
    local nopasswd="$2"
    local sudoers_file="${SUDOERS_DIR}/10-${target_user}"
    local tmp_sudoers="${SUDOERS_DIR}/.tmp_10_${target_user}.$$"

    TMP_FILES+=("$tmp_sudoers")
    mkdir -p "$SUDOERS_DIR"
    chmod 0750 "$SUDOERS_DIR"

    if [[ "$nopasswd" == "true" ]]; then
        cat <<EOF > "$tmp_sudoers"
# Omarchy-WSL Administrative Privileges (Passwordless)
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$target_user ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    else
        cat <<EOF > "$tmp_sudoers"
# Omarchy-WSL Administrative Privileges (Password Required)
%wheel ALL=(ALL:ALL) ALL
$target_user ALL=(ALL:ALL) ALL
EOF
    fi

    chmod 0440 "$tmp_sudoers"
    chown root:root "$tmp_sudoers" 2>/dev/null || true

    # Validate syntax with visudo if available
    if command -v visudo >/dev/null 2>&1; then
        if visudo -cqf "$tmp_sudoers" >/dev/null 2>&1; then
            mv -f "$tmp_sudoers" "$sudoers_file"
            chmod 0440 "$sudoers_file"
        else
            rm -f "$tmp_sudoers"
            log_err "Sudoers rule failed visudo validation! Aborting sudoers installation."
            return 1
        fi
    else
        mv -f "$tmp_sudoers" "$sudoers_file"
        chmod 0440 "$sudoers_file"
    fi

    # Ensure /etc/sudoers includes /etc/sudoers.d
    if [[ -f /etc/sudoers ]]; then
        if ! grep -qE '^(@includedir|#includedir)[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
            printf "\n@includedir %s\n" "$SUDOERS_DIR" >> /etc/sudoers 2>/dev/null || true
        fi
    fi

    log_success "Configured sudoers permissions for '$target_user'."
}

# ------------------------------------------------------------------------------
# 7. Systemd User Lingering Engine
# ------------------------------------------------------------------------------
# Writes the linger marker directly to /var/lib/systemd/linger/ so lingering
# persists even before dbus/systemd-logind is running, avoiding bus failures.
configure_systemd_linger() {
    local target_user="$1"

    mkdir -p "$LINGER_DIR"
    touch "${LINGER_DIR}/${target_user}"
    chmod 0644 "${LINGER_DIR}/${target_user}"
    chown root:root "${LINGER_DIR}/${target_user}" 2>/dev/null || true

    # Also notify loginctl if systemd is active as PID 1
    if [[ $(ps -p 1 -o comm= 2>/dev/null || true) == "systemd" ]] && command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$target_user" 2>/dev/null || true
    fi

    log_success "Enabled systemd user lingering for '$target_user'."
}

# ------------------------------------------------------------------------------
# 8. Atomic /etc/wsl.conf Updater
# ------------------------------------------------------------------------------
# Preserves existing configuration while safely inserting or updating [user] default.
update_wsl_conf() {
    local target_user="$1"
    local tmp_wsl_conf="${WSL_CONF_FILE}.tmp.$$"

    TMP_FILES+=("$tmp_wsl_conf")
    mkdir -p "$(dirname "$WSL_CONF_FILE")"

    if [[ -f "$WSL_CONF_FILE" ]]; then
        awk -v new_user="$target_user" '
BEGIN {
    in_user = 0
    user_found = 0
    default_written = 0
}
/^[ \t]*\[[ \t]*user[ \t]*\]/ {
    in_user = 1
    user_found = 1
    print $0
    next
}
/^[ \t]*\[/ {
    if (in_user && !default_written) {
        print "default = " new_user
        default_written = 1
    }
    in_user = 0
    print $0
    next
}
in_user && /^[ \t]*default[ \t]*=/ {
    print "default = " new_user
    default_written = 1
    next
}
{
    print $0
}
END {
    if (in_user && !default_written) {
        print "default = " new_user
    } else if (!user_found) {
        if (NR > 0) print ""
        print "[user]"
        print "default = " new_user
    }
}
' "$WSL_CONF_FILE" > "$tmp_wsl_conf"
    else
        cat <<EOF > "$tmp_wsl_conf"
# /etc/wsl.conf - Omarchy-WSL Base System Configuration
[boot]
systemd = true

[network]
generateResolvConf = true

[interop]
enabled = true
appendWindowsPath = false

[automount]
enabled = true
mountFsTab = true
root = /mnt/
options = "metadata,uid=1000,gid=1000,umask=022,fmask=011,case=off"

[user]
default = $target_user
EOF
    fi

    chmod 0644 "$tmp_wsl_conf"
    chown root:root "$tmp_wsl_conf" 2>/dev/null || true
    sync 2>/dev/null || true
    mv -f "$tmp_wsl_conf" "$WSL_CONF_FILE"

    log_success "Updated $WSL_CONF_FILE with default user '$target_user'."
}

# ------------------------------------------------------------------------------
# 9. Home Directory & Single-Root ~/hermes Scaffolding
# ------------------------------------------------------------------------------
scaffold_home_directory() {
    local target_user="$1"
    local home_dir
    home_dir=$(getent passwd "$target_user" | cut -d: -f6)

    [[ -d "$home_dir" ]] || mkdir -p "$home_dir"

    # Seed skeleton files if missing
    if [[ -d /etc/skel ]]; then
        for skel in /etc/skel/.[!.]* /etc/skel/*; do
            [[ -e "$skel" ]] || continue
            local base
            base=$(basename "$skel")
            if [[ ! -e "${home_dir}/${base}" ]]; then
                cp -a "$skel" "${home_dir}/${base}" 2>/dev/null || true
            fi
        done
    fi

    # Create standard workspace tree
    mkdir -p \
        "${home_dir}/.config" \
        "${home_dir}/.local/bin" \
        "${home_dir}/.local/share" \
        "${home_dir}/.local/state"

    for hdir in "${HERMES_DIRS[@]}"; do
        mkdir -p "${home_dir}/hermes/${hdir}"
    done

    chown -R "${target_user}:${target_user}" "$home_dir"
    chmod 0700 "$home_dir"

    log_success "Scaffolded single-root workspace in '$home_dir/hermes'."
}

# ------------------------------------------------------------------------------
# 10. Omarchy User Environment & Theming Bridge
# ------------------------------------------------------------------------------
setup_user_environment() {
    local target_user="$1"
    local home_dir
    home_dir=$(getent passwd "$target_user" | cut -d: -f6)

    as_user() {
        runuser -u "$target_user" -- env -i HOME="$home_dir" USER="$target_user" LOGNAME="$target_user" \
            SHELL="/bin/bash" PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
            TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}" \
            OMARCHY_PATH=/usr/share/omarchy "$@"
    }

    # Neovim setup
    if command -v omarchy-nvim-setup >/dev/null 2>&1; then
        as_user omarchy-nvim-setup >/dev/null 2>&1 || true
    fi

    # Default Theme application
    local theme_name_file="${home_dir}/.local/state/omarchy/current/theme.name"
    if [[ ! -s "$theme_name_file" ]] && command -v omarchy-theme-set >/dev/null 2>&1; then
        log_info "Applying default theme '$DEFAULT_THEME' for '$target_user'..."
        as_user env OMARCHY_WSL_THEME_BRIDGE=0 omarchy-theme-set "$DEFAULT_THEME" 2>/dev/null || true
    fi

    # Btop theme symlink
    if [[ -d "${home_dir}/.config" ]]; then
        as_user install -d "${home_dir}/.config/btop/themes" 2>/dev/null || true
        if [[ -f "${home_dir}/.local/state/omarchy/current/theme/btop.theme" ]]; then
            as_user ln -snf "${home_dir}/.local/state/omarchy/current/theme/btop.theme" \
                "${home_dir}/.config/btop/themes/current.theme" 2>/dev/null || true
        fi
    fi

    # Mise toolchain settings
    if command -v mise >/dev/null 2>&1; then
        as_user mise settings set upgrade.auto_prune false >/dev/null 2>&1 || true
    fi

    # Purge any setup history artifacts
    rm -f "${home_dir}/".*_history "${home_dir}/.lesshst" "${home_dir}/.viminfo" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 11. Kernel Sysctl Stability & Cgroup v2 Resource Governance
# ------------------------------------------------------------------------------
configure_resource_governance() {
    local target_user="$1"
    log_step "Hardening kernel sysctl memory parameters and cgroup governance..."

    # 1. Install & apply sysctl stability rules
    mkdir -p /etc/sysctl.d
    if [[ -f /usr/lib/omarchy-wsl/sysctl.d/99-omarchy-wsl.conf ]]; then
        cp -f /usr/lib/omarchy-wsl/sysctl.d/99-omarchy-wsl.conf /etc/sysctl.d/
    fi
    if [[ -f /usr/lib/omarchy-wsl/99-zz-omarchy-wsl-stability.conf ]]; then
        cp -f /usr/lib/omarchy-wsl/99-zz-omarchy-wsl-stability.conf /etc/sysctl.d/
    fi
    # Apply immediately
    if [[ -f /etc/sysctl.d/99-zz-omarchy-wsl-stability.conf ]]; then
        sysctl -q -p /etc/sysctl.d/99-zz-omarchy-wsl-stability.conf 2>/dev/null || true
    fi

    # 2. Install systemd cgroup v2 slice definitions
    if [[ -d /usr/lib/omarchy-wsl/cgroups ]]; then
        mkdir -p /etc/systemd/system/user-.slice.d /etc/systemd/oomd.conf.d
        [[ -f /usr/lib/omarchy-wsl/cgroups/build.slice ]] && \
            cp -f /usr/lib/omarchy-wsl/cgroups/build.slice /etc/systemd/system/build.slice
        [[ -f /usr/lib/omarchy-wsl/cgroups/10-interactive-protection.conf ]] && \
            cp -f /usr/lib/omarchy-wsl/cgroups/10-interactive-protection.conf /etc/systemd/system/user-.slice.d/
        [[ -f /usr/lib/omarchy-wsl/cgroups/10-omarchy-oomd.conf ]] && \
            cp -f /usr/lib/omarchy-wsl/cgroups/10-omarchy-oomd.conf /etc/systemd/oomd.conf.d/
        [[ -f /usr/lib/omarchy-wsl/cgroups/omarchy-cgroup-profile.sh ]] && \
            cp -f /usr/lib/omarchy-wsl/cgroups/omarchy-cgroup-profile.sh /etc/profile.d/omarchy-cgroup-governance.sh
    fi

    # 3. Ensure /usr/bin/omarchy-build is available
    if [[ -f /usr/lib/omarchy-wsl/bin/omarchy-build && ! -f /usr/bin/omarchy-build ]]; then
        install -m 0755 /usr/lib/omarchy-wsl/bin/omarchy-build /usr/bin/omarchy-build
    fi

    # Reload systemd if running
    if [[ $(ps -p 1 -o comm= 2>/dev/null) == "systemd" ]]; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    log_success "Kernel stability sysctl and cgroup v2 governance enforced."
}

# ------------------------------------------------------------------------------
# 12. Sentinel Record
# ------------------------------------------------------------------------------
write_sentinel() {
    local target_user="$1"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

    mkdir -p "$SENTINEL_DIR"
    cat <<EOF > "$SENTINEL_FILE"
# Omarchy OOBE Completion Sentinel
OOBE_VERSION=${OOBE_VERSION}
PROVISIONED_USER=${target_user}
PROVISIONED_UID=${TARGET_UID}
COMPLETED_AT=${now}
EOF
    chmod 0644 "$SENTINEL_FILE"

    cat <<EOF > "$USER_CONF_FILE"
# /etc/omarchy-user.conf
DEFAULT_USER=${target_user}
EOF
    chmod 0644 "$USER_CONF_FILE"

    log_success "Recorded OOBE completion sentinel in $SENTINEL_FILE."
}

# ------------------------------------------------------------------------------
# 12. Interactive Password Prompt
# ------------------------------------------------------------------------------
prompt_password() {
    local target_user="$1"
    local pass1 pass2
    local nopasswd="true"

    while true; do
        printf "\nSet a UNIX password for '%s' (leave blank for passwordless sudo): " "$target_user"
        read -r -s pass1
        printf "\n"

        if [[ -z "$pass1" ]]; then
            log_info "No password entered. Configuring passwordless sudo."
            passwd -d "$target_user" 2>/dev/null || passwd -l "$target_user" 2>/dev/null || true
            nopasswd="true"
            break
        fi

        printf "Retype password: "
        read -r -s pass2
        printf "\n"

        if [[ "$pass1" != "$pass2" ]]; then
            log_err "Passwords do not match. Please try again."
            continue
        fi

        # Apply password
        if echo "${target_user}:${pass1}" | chpasswd 2>/dev/null; then
            log_success "Password set successfully."
        else
            printf '%s\n%s\n' "$pass1" "$pass1" | passwd "$target_user" 2>/dev/null || true
        fi

        printf "Require password for 'sudo' commands? [y/N]: "
        local req_sudo
        read -r req_sudo
        if [[ "$req_sudo" =~ ^[yY] ]]; then
            nopasswd="false"
        else
            nopasswd="true"
        fi
        break
    done

    printf '%s' "$nopasswd"
}

# ------------------------------------------------------------------------------
# 13. UI Banner
# ------------------------------------------------------------------------------
show_banner() {
    cat <<'EOF'
  ██████╗ ███╗   ███╗ █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗
 ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝
 ██║   ██║██╔████╔██║███████║██████╔╝██║     ███████║ ╚████╔╝ 
 ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝  
 ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║   
  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   
             Dynamic Out-Of-Box Experience (OOBE)
EOF
    printf "\n"
}

# ------------------------------------------------------------------------------
# Main Execution Entrypoint
# ------------------------------------------------------------------------------
main() {
    # Root privilege validation
    (( EUID == 0 )) || die "OOBE must run as root (EUID 0). Invocation aborted."

    local force=false
    local headless=false
    local explicit_user=""
    local nopasswd="true"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift ;;
            --headless|--unattended|--non-interactive)
                headless=true
                shift ;;
            --user|-u)
                explicit_user="$2"
                shift 2 ;;
            --require-password)
                nopasswd="false"
                shift ;;
            --version|-v)
                echo "omarchy-oobe version ${OOBE_VERSION}"
                exit 0 ;;
            --help|-h)
                cat <<HELP
Usage: oobe.sh [OPTIONS]

Options:
  --user <NAME>         Specify target username explicitly
  --headless            Run in unattended mode without interactive prompts
  --force               Re-run OOBE even if sentinel indicates completion
  --require-password    Enforce password prompt for sudo
  --version             Print OOBE version
  --help                Show this message
HELP
                exit 0 ;;
            *)
                shift ;;
        esac
    done

    # Fast-path Idempotency check: Exit immediately if already completed unless --force
    if [[ -f "$SENTINEL_FILE" && "$force" == "false" ]]; then
        local prov_user
        prov_user=$(grep -E '^PROVISIONED_USER=' "$SENTINEL_FILE" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$prov_user" ]] && id -u "$prov_user" >/dev/null 2>&1; then
            log_info "Omarchy OOBE already completed for user '$prov_user' (UID $TARGET_UID). Exiting."
            exit 0
        fi
    fi

    # Pacman Keyring initialization if available
    if [[ -x /usr/lib/omarchy-wsl/pacman-init.sh ]]; then
        /usr/lib/omarchy-wsl/pacman-init.sh || log_warn "Pacman keyring initialization returned non-zero."
    elif [[ -x /wsl/pacman-init.sh ]]; then
        /wsl/pacman-init.sh || log_warn "Pacman keyring initialization returned non-zero."
    fi

    # Network, DNS, and Corporate Proxy synchronization
    if command -v omarchy-dns-sync >/dev/null 2>&1; then
        omarchy-dns-sync sync 2>/dev/null || true
    elif [[ -x /usr/lib/omarchy-wsl/omarchy-dns-sync ]]; then
        /usr/lib/omarchy-wsl/omarchy-dns-sync sync 2>/dev/null || true
    fi

    if command -v omarchy-ca-sync >/dev/null 2>&1; then
        omarchy-ca-sync 2>/dev/null || true
    elif [[ -x /usr/lib/omarchy-wsl/omarchy-ca-sync ]]; then
        /usr/lib/omarchy-wsl/omarchy-ca-sync 2>/dev/null || true
    fi

    if command -v omarchy-proxy-sync >/dev/null 2>&1; then
        omarchy-proxy-sync 2>/dev/null || true
    elif [[ -x /usr/lib/omarchy-wsl/omarchy-proxy-sync ]]; then
        /usr/lib/omarchy-wsl/omarchy-proxy-sync 2>/dev/null || true
    fi

    # Detect interactive vs headless execution
    # If stdin or stdout is not a TTY, force headless mode
    if [[ ! -t 0 || ! -t 1 || "${CI:-}" == "true" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
        headless=true
    fi

    local target_user=""

    if [[ -n "$explicit_user" ]]; then
        target_user=$(sanitize_username "$explicit_user")
    else
        local detected_raw
        detected_raw=$(detect_windows_username)
        local detected_clean
        detected_clean=$(sanitize_username "$detected_raw")

        if [[ "$headless" == "true" ]]; then
            target_user="$detected_clean"
        else
            show_banner
            printf "Detected Windows host username: %s%s%s\n\n" "${C_BOLD}${C_GREEN}" "$detected_clean" "${C_RESET}"
            printf "Enter UNIX username [%s]: " "$detected_clean"
            local input_name=""
            read -r input_name
            if [[ -n "$input_name" ]]; then
                target_user=$(sanitize_username "$input_name")
            else
                target_user="$detected_clean"
            fi
        fi
    fi

    # System collision check and resolution
    target_user=$(resolve_name_collision "$target_user" "$([ "$headless" == "true" ] && echo "false" || echo "true")")

    log_step "Provisioning Omarchy for user '$target_user'..."

    # 1. Provision account with UID 1000
    provision_user_account "$target_user"

    # 2. Secondary groups
    assign_secondary_groups "$target_user"

    # 3. Interactive password or passwordless sudo
    if [[ "$headless" == "true" ]]; then
        passwd -d "$target_user" 2>/dev/null || passwd -l "$target_user" 2>/dev/null || true
        nopasswd="true"
    else
        nopasswd=$(prompt_password "$target_user")
    fi

    # 4. Sudoers
    configure_sudoers "$target_user" "$nopasswd"

    # 5. Systemd lingering
    configure_systemd_linger "$target_user"

    # 6. Atomic /etc/wsl.conf update
    update_wsl_conf "$target_user"

    # 7. Home directory and ~/hermes scaffolding
    scaffold_home_directory "$target_user"

    # 8. User environment & theme setup
    setup_user_environment "$target_user"

    # 9. Kernel sysctl memory tunables & cgroup v2 resource governance
    configure_resource_governance "$target_user"

    # 10. Mark completion sentinel
    write_sentinel "$target_user"

    log_success "Omarchy user provisioning complete for '$target_user' (UID $TARGET_UID)!"
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup EXIT INT TERM HUP
    main "$@"
fi
