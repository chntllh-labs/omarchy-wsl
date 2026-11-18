#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: First-Launch Out-Of-Box Experience (OOBE)
# /usr/lib/wsl/oobe.sh   (compat symlink: /usr/lib/omarchy-wsl/oobe.sh)
# ==============================================================================
# Run as root by WSL on first launch ([oobe] command in /etc/wsl-distribution.conf;
# WSL then starts uid 1000), by /etc/profile.d/00-omarchy-firstboot.sh after
# `wsl --import`, and by image tests (`oobe.sh --headless --user devuser`).
#
# What it does (docs/OOBE-SPECIFICATION.md):
#   - creates the owner account with uid 1000, or adopts an existing uid 1000
#     that was never provisioned. An existing uid 1000 is never renamed and
#     its processes are never killed (renames: omarchy-rename-owner);
#   - owner-only sudoers drop-in (passwordless by default; --require-password),
#     systemd linger, /etc/wsl.conf [user] default, home scaffolding and the
#     Omarchy user environment (theme, nvim, mise) when those helpers exist;
#   - links the Windows tool shims (wsl-shims-setup.sh) while the launching
#     Windows user's interop session exists (skipped without interop);
#   - records /var/lib/omarchy/oobe_completed (keyed on uid 1000) and
#     /etc/omarchy-user.conf, both written atomically.
#
# It never hangs without a terminal: prompts read and write /dev/tty only (never
# stdin/stdout, never inside $(...)), it runs headless when no terminal can be
# opened, under CI=true, or over SSH without --user, and every external helper
# and Windows interop call is bounded by timeout(1).
#
# Exit codes: 0 provisioned, or already provisioned (no-op) · 1 failure ·
# 2 usage or invalid --user · 3 precondition (not root, uid 1000 already owned
# by another name, name collision) · 75 another OOBE or omarchy-rename-owner
# holds the lock · 128+n interrupted by signal n (129 HUP, 130 INT, 143 TERM).
#
# Test seams (in addition to those of account.sh):
#   OMARCHY_WSL_LIB_DIR        directory holding account.sh/common.sh
#   OMARCHY_PACMAN_INIT        keyring initializer ("" disables)
#   OMARCHY_DRVFS_ROOTS        space-separated Windows drive mounts (e.g. /mnt/c)
#   OMARCHY_PROC_CMDLINE       alternate /proc/cmdline
#   OMARCHY_NO_TTY=1           behave as if no terminal could be opened
#   OMARCHY_TTY_IN/_OUT        files used instead of /dev/tty (prompt tests)
#   OMARCHY_SYNC_TIMEOUT       seconds per --sync-network tool (default 20)
#   OMARCHY_SHIMS_SETUP        Windows shim installer ("" disables)
#   OMARCHY_SHIMS_TIMEOUT      seconds for the shim installer (default 30)
#   OMARCHY_BINFMT_DIR         alternate /proc/sys/fs/binfmt_misc
#   OMARCHY_ALLOW_NONROOT=1    skip the root check (sandboxed tests only)
# ==============================================================================

set -euo pipefail

OOBE_VERSION="2.0.0"
DEFAULT_THEME="Tokyo Night"
SYNC_TIMEOUT="${OMARCHY_SYNC_TIMEOUT:-20}"
[[ "$SYNC_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]] || SYNC_TIMEOUT=20
SHIMS_TIMEOUT="${OMARCHY_SHIMS_TIMEOUT:-30}"
[[ "$SHIMS_TIMEOUT" =~ ^[1-9][0-9]{0,2}$ ]] || SHIMS_TIMEOUT=30
OWNER_GROUP_CANDIDATES=(wheel docker video render input audio)

_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
for _lib in \
  "${OMARCHY_WSL_LIB_DIR:+$OMARCHY_WSL_LIB_DIR/omarchy-wsl-account.sh}" \
  "${OMARCHY_WSL_LIB_DIR:+$OMARCHY_WSL_LIB_DIR/account.sh}" \
  "${_self%/*}/../lib/omarchy-wsl-account.sh" \
  "${_self%/*}/../omarchy-wsl/account.sh" \
  /usr/lib/omarchy-wsl/account.sh; do
  # shellcheck source=SCRIPTDIR/../lib/omarchy-wsl-account.sh
  [[ -n "$_lib" && -r "$_lib" ]] && { source "$_lib"; break; }
done
unset _lib
declare -F owner_name >/dev/null || { echo "oobe.sh: account library not found (expected /usr/lib/omarchy-wsl/account.sh)" >&2; exit 1; }
# shellcheck disable=SC2034  # read by the logging functions in common.sh
OMW_TAG="omarchy-oobe"

# Options
OPT_USER=""
OPT_HEADLESS=0
OPT_FORCE=0
OPT_REQUIRE_PASSWORD=0
OPT_PASSWORD_STDIN=0
OPT_SYNC_NETWORK=0

# State
INTERACTIVE=0
TTY_SAVED=""
MODE=""          # create | adopt | force
OWNER=""
OWNER_GID=""
HOME_DIR=""
HOME_FRESH=0
PASSWORD_SET=0
SUDO_MODE="nopasswd"

usage() {
  cat <<'EOF'
Usage: oobe.sh [options]

Provision the Omarchy-WSL owner account (uid 1000). Must run as root.

Options:
  -u, --user NAME        Owner name. Must already be valid (^[a-z_][a-z0-9_-]*$,
                         at most 31 characters, not a system name); it is not
                         transliterated. OMARCHY_USER=NAME is equivalent.
      --headless         Never prompt (aliases: --unattended, --non-interactive).
                         Implied when no terminal can be opened, under CI=true,
                         and over SSH (SSH_CONNECTION/SSH_TTY) without --user.
      --require-password sudo asks for the owner's password. Interactive runs
                         insist on a password; headless runs need
                         --password-stdin, otherwise the password stays locked.
      --password-stdin   Read the owner's password from the first line of stdin.
      --sync-network     Also run omarchy-dns-sync, omarchy-ca-sync and
                         omarchy-proxy-sync now (each bounded by 20 s). They
                         run from systemd at every boot anyway.
      --force            Re-apply groups, sudoers, linger, wsl.conf, home
                         scaffolding and the sentinel for the existing owner.
                         Never renames the account.
  -h, --help             Show this help and exit.
      --version          Print the version and exit.

An existing uid 1000 is never renamed. To rename the owner, run as root:
  omarchy-rename-owner NEW-NAME

Exit codes: 0 ok or already provisioned, 1 failure, 2 usage, 3 precondition,
75 busy (lock held), 128+n interrupted by signal n.
EOF
}

usage_error() {
  omw_err "$*"
  usage >&2
  exit 2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user)
        [[ $# -ge 2 && -n "$2" ]] || usage_error "$1 requires a NAME"
        OPT_USER="$2"
        shift 2 ;;
      --user=*)
        OPT_USER="${1#*=}"
        [[ -n "$OPT_USER" ]] || usage_error "--user requires a NAME"
        shift ;;
      --headless|--unattended|--non-interactive) OPT_HEADLESS=1; shift ;;
      --require-password) OPT_REQUIRE_PASSWORD=1; shift ;;
      --password-stdin) OPT_PASSWORD_STDIN=1; shift ;;
      --sync-network) OPT_SYNC_NETWORK=1; shift ;;
      --force) OPT_FORCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) echo "omarchy-oobe ${OOBE_VERSION}"; exit 0 ;;
      --) shift; [[ $# -eq 0 ]] || usage_error "unexpected argument: $1"; break ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  if [[ -z "$OPT_USER" && -n "${OMARCHY_USER:-}" ]]; then
    OPT_USER="$OMARCHY_USER"
  fi
}

# -----------------------------------------------------------------------------
# Traps: EXIT keeps the exit status; signals never exit 0.
# -----------------------------------------------------------------------------
_restore_tty() {
  if [[ -n "$TTY_SAVED" ]]; then
    stty "$TTY_SAVED" <&3 2>/dev/null || true
    TTY_SAVED=""
  fi
}

on_exit() {
  local rc=$?
  omw_cleanup_tmp
  _restore_tty
  exit "$rc"
}

on_signal() {
  local sig="$1" num="$2"
  trap - EXIT INT TERM HUP
  omw_cleanup_tmp
  _restore_tty
  omw_err "Interrupted by SIG${sig}; provisioning is incomplete. Run the OOBE again to finish."
  exit $((128 + num))
}

install_traps() {
  trap on_exit EXIT
  trap 'on_signal INT 2' INT
  trap 'on_signal TERM 15' TERM
  trap 'on_signal HUP 1' HUP
}

# -----------------------------------------------------------------------------
# Terminal I/O: fd 3 reads from the terminal, fd 4 writes to it.
# -----------------------------------------------------------------------------
open_terminal() {
  if [[ -n "${OMARCHY_TTY_IN:-}" ]]; then
    exec 3<"$OMARCHY_TTY_IN" 4>>"${OMARCHY_TTY_OUT:-/dev/null}"
    return 0
  fi
  omw_have_tty || return 1
  { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null || return 1
  TTY_SAVED="$(stty -g <&3 2>/dev/null || true)"
  return 0
}

decide_interactivity() {
  INTERACTIVE=0
  if (( OPT_HEADLESS )); then
    return 0
  fi
  if [[ "${CI:-}" == "true" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
    omw_log "CI/noninteractive environment detected: running headless."
    return 0
  fi
  if [[ -z "$OPT_USER" && ( -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ) ]]; then
    omw_log "SSH session without --user: running headless (pass --user NAME to choose the owner)."
    return 0
  fi
  if open_terminal; then
    INTERACTIVE=1
  else
    omw_log "No terminal available: running headless."
  fi
}

say() { printf '%s\n' "$*" >&4; }

# ask <VAR> <prompt> [silent] -> 0, or 1 on EOF
ask() {
  local __var="$1" __prompt="$2" __mode="${3:-}" __ans=""
  printf '%s' "$__prompt" >&4
  if [[ "$__mode" == "silent" ]]; then
    IFS= read -r -s -u 3 __ans || { printf '\n' >&4; return 1; }
    printf '\n' >&4
  else
    IFS= read -r -u 3 __ans || { printf '\n' >&4; return 1; }
  fi
  __ans="${__ans%$'\r'}"
  printf -v "$__var" '%s' "$__ans"
}

show_banner() {
  cat >&4 <<'EOF'

  ██████╗ ███╗   ███╗ █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗
 ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝
 ██║   ██║██╔████╔██║███████║██████╔╝██║     ███████║ ╚████╔╝
 ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝
 ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║
  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝
                 Omarchy for WSL: first-launch setup

EOF
}

# -----------------------------------------------------------------------------
# Windows user-name detection (suggestions only; always bounded)
# -----------------------------------------------------------------------------
# Windows drive mounts that hold a Windows directory (DrvFs over 9p/virtiofs).
drvfs_roots() {
  local m fstype seen=" "
  if [[ -n "${OMARCHY_DRVFS_ROOTS:-}" ]]; then
    local -a roots=()
    read -r -a roots <<<"$OMARCHY_DRVFS_ROOTS"
    printf '%s\n' ${roots[@]+"${roots[@]}"}
    return 0
  fi
  [[ -r /proc/mounts ]] || return 0
  while read -r _ m fstype _; do
    case "$fstype" in 9p|drvfs|virtiofs) ;; *) continue ;; esac
    case "$m" in */[a-z]) ;; *) continue ;; esac
    case "$seen" in *" $m "*) continue ;; esac
    seen="${seen}${m} "
    printf '%s\n' "$m"
  done </proc/mounts
}

# Prints a raw (unsanitized) Windows user name, or nothing.
detect_windows_username() {
  local v tok root out d base n=0 cand="" over_ssh=0
  local -a toks=()
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]] && over_ssh=1

  # 1. Kernel command line (.wslconfig kernelCommandLine = omarchy.user=NAME)
  local cmdline="${OMARCHY_PROC_CMDLINE:-/proc/cmdline}"
  if [[ -r "$cmdline" ]]; then
    v="$(tr ' ' '\n' <"$cmdline" | sed -n 's/^omarchy\.user=//p' | head -n 1)"
    if [[ -n "$v" ]]; then printf '%s\n' "$v"; return 0; fi
  fi

  # 2. %USERNAME% forwarded through WSLENV
  if [[ -n "${USERNAME:-}" && -n "${WSLENV:-}" ]]; then
    IFS=: read -r -a toks <<<"$WSLENV"
    for tok in ${toks[@]+"${toks[@]}"}; do
      if [[ "${tok%%/*}" == "USERNAME" ]]; then printf '%s\n' "$USERNAME"; return 0; fi
    done
  fi

  # 3. cmd.exe, run from a DrvFs cwd with a timeout. Skipped over SSH: the
  #    Windows identity behind an SSH session may be a service account.
  if (( ! over_ssh )) && omw_have timeout; then
    while IFS= read -r root; do
      [[ -n "$root" && -x "$root/Windows/System32/cmd.exe" ]] || continue
      out="$(cd "$root" 2>/dev/null && timeout --kill-after=2 5 "$root/Windows/System32/cmd.exe" /d /c "echo %USERNAME%" \
             </dev/null 2>/dev/null 3>&- 4>&- 9>&- | tr -d '\r\n')" || out=""
      if [[ -n "$out" && "$out" != *%* ]]; then printf '%s\n' "$out"; return 0; fi
    done < <(drvfs_roots)
  fi

  # 4. Exactly one real profile under <drive>/Users (ambiguity = no guess).
  while IFS= read -r root; do
    [[ -n "$root" && -d "$root/Users" ]] || continue
    for d in "$root/Users"/*; do
      [[ -d "$d" && ! -L "$d" ]] || continue
      base="${d##*/}"
      case "$base" in
        Default|"Default User"|Public|"All Users"|Administrator|WDAGUtilityAccount|defaultuser0|desktop.ini|.*) continue ;;
      esac
      n=$((n + 1))
      cand="$base"
    done
  done < <(drvfs_roots)
  if (( n == 1 )); then printf '%s\n' "$cand"; fi
  return 0
}

# -----------------------------------------------------------------------------
# Owner selection
# -----------------------------------------------------------------------------
choose_new_owner() {
  local suggestion preseed detected input tries=0
  if [[ -n "$OPT_USER" ]]; then
    if ! validate_username "$OPT_USER"; then
      omw_fail 2 "Invalid user name: $OMW_ACCT_REASON. A valid name derived from it: $(suggest_username "$OPT_USER")"
    fi
    if omw_name_conflict "$OPT_USER" create; then
      omw_fail 3 "Cannot create '$OPT_USER': $OMW_ACCT_REASON."
    fi
    OWNER="$OPT_USER"
    return 0
  fi

  preseed="$(user_conf_default_user)"
  if [[ -n "$preseed" ]] && ! omw_name_conflict "$preseed" create; then
    suggestion="$preseed"
    omw_log "Using DEFAULT_USER=$preseed from $OMW_USER_CONF."
  else
    [[ -n "$preseed" ]] && omw_warn "Ignoring DEFAULT_USER=$preseed from $OMW_USER_CONF: $OMW_ACCT_REASON."
    detected="$(detect_windows_username)"
    suggestion="$(suggest_username "$detected")"
    if [[ -n "$detected" ]]; then
      omw_log "Windows user '$detected' -> suggested Linux user '$suggestion'."
    fi
  fi

  if (( ! INTERACTIVE )); then
    OWNER="$suggestion"
    return 0
  fi

  show_banner
  say "Choose the name of your Linux account (uid 1000)."
  while :; do
    tries=$((tries + 1))
    (( tries <= 5 )) || omw_fail 2 "No valid user name after 5 attempts."
    input=""
    ask input "Linux user name [${suggestion}]: " || omw_fail 1 "Terminal closed while asking for the user name."
    [[ -n "$input" ]] || input="$suggestion"
    if ! validate_username "$input"; then
      say "  Not accepted: $OMW_ACCT_REASON."
      say "  Suggestion: $(suggest_username "$input")"
      continue
    fi
    if omw_name_conflict "$input" create; then
      say "  Not accepted: $OMW_ACCT_REASON."
      continue
    fi
    OWNER="$input"
    return 0
  done
}

# -----------------------------------------------------------------------------
# Provisioning steps
# -----------------------------------------------------------------------------
init_pacman_keyring() {
  local p="${OMARCHY_PACMAN_INIT-/usr/lib/omarchy-wsl/pacman-init.sh}"
  [[ -n "$p" && -x "$p" ]] || return 0
  omw_step "Initializing the pacman keyring"
  if ! _omw_bounded 300 "$p" </dev/null 3>&- 4>&- 9>&-; then
    omw_warn "Pacman keyring initialization failed or timed out; run $p as root later."
  fi
}

sync_network() {
  local tool path
  local -a args
  for tool in omarchy-dns-sync omarchy-ca-sync omarchy-proxy-sync; do
    path="$(command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$path" && -x "/usr/lib/omarchy-wsl/$tool" ]]; then
      path="/usr/lib/omarchy-wsl/$tool"
    fi
    if [[ -z "$path" ]]; then
      continue
    fi
    args=()
    if [[ "$tool" == "omarchy-dns-sync" ]]; then
      args=(sync)
    fi
    omw_step "Running $tool (bounded to ${SYNC_TIMEOUT} s)"
    if ! _omw_bounded "$SYNC_TIMEOUT" "$path" ${args[@]+"${args[@]}"} </dev/null 3>&- 4>&- 9>&-; then
      omw_warn "$tool failed or timed out (it runs again at boot)."
    fi
  done
}

create_owner() {
  local name="$OWNER" home huid
  home="$OMW_HOME_ROOT/$name"
  HOME_FRESH=1
  if [[ -e "$home" || -L "$home" ]]; then
    if [[ -L "$home" || ! -d "$home" ]]; then
      omw_fail 3 "$home exists and is not a directory; refusing to create the owner there."
    fi
    huid="$(stat -c %u "$home" 2>/dev/null || echo unknown)"
    if [[ "$huid" != "$OMW_OWNER_UID" ]]; then
      omw_fail 3 "$home already exists and belongs to uid $huid; move it aside before creating '$name'."
    fi
    HOME_FRESH=0
    omw_warn "Reusing the existing $home (already owned by uid $OMW_OWNER_UID)."
  fi

  if omw_group_exists "$name"; then
    omw_log "Reusing group '$name' (gid $(omw_group_gid "$name")) as the primary group."
  elif omw_getent group "$OMW_OWNER_UID" >/dev/null 2>&1; then
    omw_warn "gid $OMW_OWNER_UID is used by group '$(omw_getent group "$OMW_OWNER_UID" | cut -d: -f1)'; creating group '$name' with the next free gid."
    groupadd "$name" || omw_die "groupadd $name failed."
  else
    groupadd -g "$OMW_OWNER_UID" "$name" || omw_die "groupadd -g $OMW_OWNER_UID $name failed."
  fi

  omw_step "Creating user '$name' (uid $OMW_OWNER_UID)"
  local -a args=(-m -u "$OMW_OWNER_UID" -g "$name" -s /bin/bash -d "$home")
  [[ -d "$OMW_SKEL_DIR" ]] && args+=(-k "$OMW_SKEL_DIR")
  useradd "${args[@]}" "$name" || omw_die "useradd failed for '$name'."
}

assign_groups() {
  local g list=""
  for g in "${OWNER_GROUP_CANDIDATES[@]}"; do
    omw_group_exists "$g" && list="${list:+$list,}$g"
  done
  [[ -n "$list" ]] || return 0
  usermod -aG "$list" "$OWNER" || omw_warn "usermod -aG $list $OWNER failed."
}

_set_password() {
  local pw="$1"
  if printf '%s:%s\n' "$OWNER" "$pw" | chpasswd; then
    PASSWORD_SET=1
    return 0
  fi
  return 1
}

configure_password() {
  local pw1="" pw2="" ans="" tries=0
  # A re-run with --force never touches an existing password.
  if [[ "$MODE" == "force" ]] && (( ! OPT_PASSWORD_STDIN )); then
    local current
    current="$(sudoers_mode_of "$OWNER")"
    if (( OPT_REQUIRE_PASSWORD )); then SUDO_MODE="password"
    elif [[ "$current" == "password" ]]; then SUDO_MODE="password"
    else SUDO_MODE="nopasswd"; fi
    return 0
  fi

  if (( OPT_PASSWORD_STDIN )); then
    IFS= read -r pw1 || true
    pw1="${pw1%$'\r'}"
    [[ -n "$pw1" ]] || omw_fail 2 "--password-stdin: no password on stdin."
    _set_password "$pw1" || omw_die "chpasswd failed for '$OWNER'."
    pw1=""
  elif (( INTERACTIVE )); then
    say ""
    if (( OPT_REQUIRE_PASSWORD )); then
      say "Set a password for '$OWNER' (sudo will ask for it)."
    else
      say "Set a password for '$OWNER', or leave it empty to keep the password"
      say "locked (sudo then works without a password)."
    fi
    while :; do
      tries=$((tries + 1))
      (( tries <= 5 )) || omw_fail 1 "No password set after 5 attempts."
      ask pw1 "New password: " silent || omw_fail 1 "Terminal closed while asking for the password."
      if [[ -z "$pw1" ]]; then
        if (( OPT_REQUIRE_PASSWORD )); then
          say "  A password is required (--require-password)."
          continue
        fi
        break
      fi
      ask pw2 "Retype password: " silent || omw_fail 1 "Terminal closed while asking for the password."
      if [[ "$pw1" != "$pw2" ]]; then
        say "  The passwords do not match."
        continue
      fi
      if _set_password "$pw1"; then
        say "  Password set."
        break
      fi
      say "  chpasswd rejected the password; try another one."
    done
    pw1="" pw2=""
  fi

  if (( ! PASSWORD_SET )); then
    # Never an empty password (passwd -d): Arch PAM accepts empty passwords
    # (nullok). A locked password still allows WSL logins, root's
    # runuser/su, and SSH public-key logins with UsePAM=yes.
    passwd -l "$OWNER" >/dev/null 2>&1 || omw_warn "passwd -l $OWNER failed."
  fi

  if (( OPT_REQUIRE_PASSWORD )); then
    SUDO_MODE="password"
  elif (( PASSWORD_SET && INTERACTIVE && ! OPT_PASSWORD_STDIN )); then
    ask ans "Ask for this password when using sudo? [y/N]: " || ans=""
    case "$ans" in [yY]*) SUDO_MODE="password" ;; *) SUDO_MODE="nopasswd" ;; esac
  else
    SUDO_MODE="nopasswd"
  fi
  if [[ "$SUDO_MODE" == "password" ]] && (( ! PASSWORD_SET )); then
    omw_warn "sudo requires a password but none is set. Set one with: wsl.exe -d ${WSL_DISTRO_NAME:-Omarchy} -u root -- passwd $OWNER"
  fi
}

# Run a command as the owner with a clean environment, bounded by <secs>.
as_owner() {
  local secs="$1"
  shift
  _omw_bounded "$secs" runuser -u "$OWNER" -- env -i \
    HOME="$HOME_DIR" USER="$OWNER" LOGNAME="$OWNER" SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
    TERM="${TERM:-xterm-256color}" LANG="${LANG:-C.UTF-8}" \
    OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
    "$@" </dev/null 3>&- 4>&- 9>&-
}

scaffold_home() {
  local d
  HOME_DIR="$(owner_home)"
  OWNER_GID="$(_omw_passwd_field "$OMW_OWNER_UID" 4)"
  case "$HOME_DIR" in
    "$OMW_HOME_ROOT"/*/*|"$OMW_HOME_ROOT"/) omw_warn "Home $HOME_DIR is not $OMW_HOME_ROOT/<name>; skipping home scaffolding."; return 0 ;;
    "$OMW_HOME_ROOT"/?*) ;;
    *) omw_warn "Home $HOME_DIR is not under $OMW_HOME_ROOT; skipping home scaffolding."; return 0 ;;
  esac
  if [[ -L "$HOME_DIR" ]]; then
    omw_warn "Home $HOME_DIR is a symlink; skipping home scaffolding."
    return 0
  fi
  if [[ ! -d "$HOME_DIR" ]]; then
    mkdir -p -- "$OMW_HOME_ROOT"
    mkdir -m 0700 -- "$HOME_DIR"
    _omw_chown "${OMW_OWNER_UID}:${OWNER_GID}" "$HOME_DIR"
    HOME_FRESH=1
    if [[ -d "$OMW_SKEL_DIR" ]]; then
      cp -a "$OMW_SKEL_DIR"/. "$HOME_DIR"/ 2>/dev/null || omw_warn "Could not copy $OMW_SKEL_DIR into $HOME_DIR."
      _omw_chown -R "${OMW_OWNER_UID}:${OWNER_GID}" "$HOME_DIR"
    fi
  fi
  chmod 0700 "$HOME_DIR"
  _omw_chown "${OMW_OWNER_UID}:${OWNER_GID}" "$HOME_DIR"

  # Directories are created AS THE OWNER: a re-run must never follow a symlink
  # the owner planted in their own home with root privileges.
  local -a dirs=(.config .local/bin .local/share .local/state)
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(user_conf_home_dirs)
  for d in "${dirs[@]}"; do
    as_owner 10 mkdir -p -- "$HOME_DIR/$d" || omw_warn "Could not create ~/$d."
  done

  if (( HOME_FRESH )); then
    # Only a home created by this run: never delete history on re-runs.
    rm -f -- "$HOME_DIR"/.*_history "$HOME_DIR/.lesshst" "$HOME_DIR/.viminfo" 2>/dev/null || true
  fi
}

# Helpers are resolved to absolute paths here: as_owner runs them with a clean
# environment (env -i), whose PATH need not contain the helper's directory.
setup_user_environment() {
  local nvim_setup theme_set mise_bin
  nvim_setup="$(command -v omarchy-nvim-setup 2>/dev/null || true)"
  theme_set="$(command -v omarchy-theme-set 2>/dev/null || true)"
  mise_bin="$(command -v mise 2>/dev/null || true)"
  if [[ -n "$nvim_setup" ]]; then
    omw_step "Setting up Neovim (omarchy-nvim-setup)"
    as_owner 300 "$nvim_setup" >/dev/null 2>&1 || omw_warn "omarchy-nvim-setup failed or timed out."
  fi
  if [[ -n "$theme_set" && ! -s "$HOME_DIR/.local/state/omarchy/current/theme.name" ]]; then
    omw_step "Applying the default theme '$DEFAULT_THEME'"
    as_owner 120 env OMARCHY_WSL_THEME_BRIDGE=0 "$theme_set" "$DEFAULT_THEME" >/dev/null 2>&1 \
      || omw_warn "omarchy-theme-set failed or timed out."
  fi
  if [[ -f "$HOME_DIR/.local/state/omarchy/current/theme/btop.theme" ]]; then
    if ! { as_owner 10 mkdir -p -- "$HOME_DIR/.config/btop/themes" \
           && as_owner 10 ln -snf -- "$HOME_DIR/.local/state/omarchy/current/theme/btop.theme" "$HOME_DIR/.config/btop/themes/current.theme"; }; then
      omw_warn "Could not link the btop theme."
    fi
  fi
  if [[ -n "$mise_bin" ]]; then
    as_owner 30 "$mise_bin" settings set upgrade.auto_prune false >/dev/null 2>&1 || omw_warn "mise settings failed."
  fi
}

# WSL registers its PE loader as binfmt "WSLInterop" (or "WSLInterop-late"
# on builds that re-register after systemd-binfmt). Absent or disabled means
# no .exe can run (containers, image builds, interop=false).
interop_enabled() {
  local d="${OMARCHY_BINFMT_DIR:-/proc/sys/fs/binfmt_misc}" e
  for e in "$d/WSLInterop" "$d/WSLInterop-late"; do
    if [[ -r "$e" ]] && head -n 1 "$e" 2>/dev/null | grep -q '^enabled'; then
      return 0
    fi
  done
  return 1
}

# Links PowerShell/cmd/wt/GCM into /usr/lib/omarchy-wsl/bin. It needs root and
# the interop session of the Windows user who launched WSL (it reads that
# user's %LOCALAPPDATA%), which only exists now. Bounded, never fatal; the
# environment is inherited so WSL_INTEROP reaches it.
setup_windows_shims() {
  local shims="${OMARCHY_SHIMS_SETUP-/usr/lib/omarchy-wsl/bin/wsl-shims-setup.sh}"
  [[ -n "$shims" && -x "$shims" ]] || return 0
  if ! interop_enabled; then
    omw_log "Windows interop is not available: skipping the Windows tool shims."
    return 0
  fi
  omw_step "Linking Windows tool shims (bounded to ${SHIMS_TIMEOUT} s)"
  if ! _omw_bounded "$SHIMS_TIMEOUT" "$shims" </dev/null 3>&- 4>&- 9>&-; then
    omw_warn "$shims failed or timed out; run it again as root once Windows interop works."
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
existing_owner_path() {
  local existing="$1" recorded
  if [[ -n "$OPT_USER" && "$OPT_USER" != "$existing" ]]; then
    omw_fail 3 "uid $OMW_OWNER_UID already belongs to '$existing'; the OOBE never renames it. To rename the owner run, as root: omarchy-rename-owner $OPT_USER"
  fi
  OWNER="$existing"
  if sentinel_provisioned && (( ! OPT_FORCE )); then
    recorded="$(sentinel_get PROVISIONED_USER 2>/dev/null || true)"
    if [[ -n "$recorded" && "$recorded" != "$existing" ]]; then
      omw_warn "The sentinel records '$recorded' but uid $OMW_OWNER_UID is '$existing'; leaving the account unchanged."
    fi
    omw_log "Already provisioned: uid $OMW_OWNER_UID is '$existing'. Nothing to do (use --force to re-apply the configuration)."
    exit 0
  fi
  if (( OPT_FORCE )) && sentinel_provisioned; then
    MODE="force"
    omw_log "Re-applying the configuration for '$existing' (--force)."
  else
    MODE="adopt"
    omw_log "Adopting the existing uid $OMW_OWNER_UID account '$existing' (not renamed)."
  fi
}

main() {
  parse_args "$@"
  if ! omw_is_root && [[ "${OMARCHY_ALLOW_NONROOT:-}" != "1" ]]; then
    omw_fail 3 "The OOBE must run as root. From Windows: wsl.exe -d ${WSL_DISTRO_NAME:-Omarchy} -u root -- /usr/lib/wsl/oobe.sh"
  fi
  install_traps
  decide_interactivity

  local rc=0
  omw_acct_lock || rc=$?
  if (( rc == 75 )); then
    omw_fail 75 "Another OOBE or omarchy-rename-owner is running (lock $OMW_LOCK_FILE). Wait for it to finish."
  elif (( rc != 0 )); then
    omw_die "Cannot take the account lock $OMW_LOCK_FILE."
  fi

  local existing=""
  existing="$(owner_name 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    existing_owner_path "$existing"
  else
    if sentinel_provisioned; then
      omw_warn "The sentinel exists but no account has uid $OMW_OWNER_UID; provisioning again."
    fi
    MODE="create"
    choose_new_owner
  fi

  omw_log "Provisioning '$OWNER' (uid $OMW_OWNER_UID, mode: $MODE)."
  init_pacman_keyring
  (( OPT_SYNC_NETWORK )) && sync_network

  [[ "$MODE" == "create" ]] && create_owner
  assign_groups
  configure_password

  local src=0
  configure_sudoers "$OWNER" "$SUDO_MODE" || src=$?
  case "$src" in
    0) omw_log "sudo: /etc/sudoers.d/10-$OWNER ($SUDO_MODE)." ;;
    3) omw_warn "sudo is not configured (visudo missing)." ;;
    *) omw_die "Could not install the sudoers drop-in for '$OWNER'." ;;
  esac

  configure_linger "$OWNER" || omw_warn "Could not enable lingering for '$OWNER'."
  update_wsl_conf_default_user "$OWNER" || omw_die "Could not set [user] default in $OMW_WSL_CONF."
  scaffold_home
  setup_user_environment
  setup_windows_shims

  write_user_conf "$OWNER" || omw_die "Could not write $OMW_USER_CONF."
  write_sentinel "$OWNER" oobe || omw_die "Could not write $OMW_SENTINEL_FILE."

  omw_log "Provisioning complete: '$OWNER' (uid $OMW_OWNER_UID), sudo $SUDO_MODE."
  if (( INTERACTIVE )); then
    say ""
    say "Welcome, $OWNER. Omarchy is ready."
  fi
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
