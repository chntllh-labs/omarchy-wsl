#!/bin/bash
# ==============================================================================
# Omarchy WSL: Out-Of-Box Experience (OOBE) User Provisioning Engine
# ==============================================================================
# Dynamic user identity, sudoers authorization, systemd lingering,
# unified ~/hermes scaffolding, and per-user state initialization.
# ==============================================================================

set -euo pipefail

CONF=${OMARCHY_USER_CONF:-/etc/omarchy-user.conf}
CONTEXT=${OMARCHY_OOBE_CONTEXT:-runtime}

OMARCHY_USER="aqua"
OMARCHY_UID=1000
OMARCHY_SHELL="/bin/bash"
OMARCHY_GROUPS="wheel docker"
OMARCHY_HERMES_DIRS="workspace worktrees scratch"
OMARCHY_THEME="Tokyo Night"
OMARCHY_GIT_NAME=""
OMARCHY_GIT_EMAIL=""

# shellcheck source=/dev/null
[[ -r "$CONF" ]] && source "$CONF"

log() { printf '[omarchy-oobe] %s\n' "$*"; }
die() { printf '[omarchy-oobe] ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die "Must run as root (sudo $0)"
[[ "$OMARCHY_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username '$OMARCHY_USER'"
[[ "$OMARCHY_UID" =~ ^[0-9]+$ ]] || die "Invalid UID '$OMARCHY_UID'"
[[ -x "$OMARCHY_SHELL" ]] || die "Shell $OMARCHY_SHELL is not executable"

user="$OMARCHY_USER"

# --- 1. Pacman Keyring Initialization ----------------------------------------
if [[ -x /usr/lib/omarchy-wsl/pacman-init.sh ]]; then
  /usr/lib/omarchy-wsl/pacman-init.sh
fi

# --- 2. User Account Creation / Synchronization ------------------------------
groups=()
for group in $OMARCHY_GROUPS; do
  getent group "$group" >/dev/null && groups+=("$group")
done
group_list=$(IFS=,; echo "${groups[*]}")

if id -u "$user" >/dev/null 2>&1; then
  log "User '$user' already exists (UID $(id -u "$user"))"
  usermod --shell "$OMARCHY_SHELL" "$user"
  [[ -n "$group_list" ]] && usermod --append --groups "$group_list" "$user"
else
  owner=$(getent passwd "$OMARCHY_UID" | cut -d: -f1 || true)
  if [[ -n "$owner" ]]; then
    uid=$(awk -F: '$3 >= 1000 && $3 < 60000 { if ($3 > max) max = $3 } END { print (max ? max + 1 : 1000) }' /etc/passwd)
    log "UID $OMARCHY_UID belongs to $owner; allocating UID $uid for $user"
  else
    uid="$OMARCHY_UID"
  fi
  log "Creating user '$user' (UID $uid)"
  useradd --create-home --uid "$uid" --user-group --shell "$OMARCHY_SHELL" \
    ${group_list:+--groups "$group_list"} "$user"
fi

home=$(getent passwd "$user" | cut -d: -f6)
[[ -d "$home" ]] || install -d -m 0700 -o "$user" -g "$user" "$home"

# --- 3. Passwordless Sudo Privileges -----------------------------------------
sudoers="/etc/sudoers.d/10-$user"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" > "${sudoers}.tmp"
chmod 0440 "${sudoers}.tmp"
visudo -cqf "${sudoers}.tmp" || die "Generated sudoers configuration failed visudo validation"
mv "${sudoers}.tmp" "$sudoers"

# --- 4. Systemd Lingering ---------------------------------------------------
if [[ $(ps -p 1 -o comm= 2>/dev/null) == systemd ]] && loginctl enable-linger "$user" 2>/dev/null; then
  log "Systemd linger enabled for $user"
else
  install -d -m 0755 /var/lib/systemd/linger
  touch "/var/lib/systemd/linger/$user"
fi

# --- 5. Default WSL User Config ----------------------------------------------
if [[ -f /etc/wsl.conf ]]; then
  if grep -q '^\[user\]' /etc/wsl.conf; then
    sed -i "/^\[user\]/,/^\[/ s/^default[[:space:]]*=.*/default = $user/" /etc/wsl.conf
  else
    printf '\n[user]\ndefault = %s\n' "$user" >> /etc/wsl.conf
  fi
fi

# --- 6. Single-Root ~/hermes Directory Tree ---------------------------------
as_user() {
  runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" SHELL="$OMARCHY_SHELL" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}" \
    OMARCHY_PATH=/usr/share/omarchy "$@"
}

for dir in $OMARCHY_HERMES_DIRS; do
  as_user install -d "$home/hermes/$dir"
done

# --- 7. Omarchy User Environment & Theming -----------------------------------
if command -v omarchy-nvim-setup >/dev/null 2>&1; then
  as_user omarchy-nvim-setup >/dev/null 2>&1 || true
fi

theme_name_file="$home/.local/state/omarchy/current/theme.name"
if [[ ! -s "$theme_name_file" ]] && command -v omarchy-theme-set >/dev/null 2>&1; then
  log "Applying default theme '$OMARCHY_THEME' for $user"
  as_user env OMARCHY_WSL_THEME_BRIDGE=0 omarchy-theme-set "$OMARCHY_THEME" 2>/dev/null || true
fi

# Btop theme symlink
if [[ -d "$home/.config" ]]; then
  as_user install -d "$home/.config/btop/themes"
  if [[ -f "$home/.local/state/omarchy/current/theme/btop.theme" ]]; then
    as_user ln -snf "$home/.local/state/omarchy/current/theme/btop.theme" "$home/.config/btop/themes/current.theme"
  fi
fi

# Toolchain settings
if command -v mise >/dev/null 2>&1; then
  as_user mise settings set upgrade.auto_prune false >/dev/null 2>&1 || true
fi

if [[ -n "$OMARCHY_GIT_NAME" ]]; then
  as_user git config --global user.name "$OMARCHY_GIT_NAME"
fi
if [[ -n "$OMARCHY_GIT_EMAIL" ]]; then
  as_user git config --global user.email "$OMARCHY_GIT_EMAIL"
fi

# Clean any shell history generated during OOBE execution
rm -f "$home/".*_history "$home/.lesshst" "$home/.viminfo" 2>/dev/null || true

log "OOBE Provisioning complete for '$user' (UID $(id -u "$user"), context: $CONTEXT)"
