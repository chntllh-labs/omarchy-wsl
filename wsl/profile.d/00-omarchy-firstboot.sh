# shellcheck shell=sh
# ==============================================================================
# Omarchy WSL: first-boot fallback for `wsl --import`
# /etc/profile.d/00-omarchy-firstboot.sh
# ==============================================================================
# `wsl --import` skips the [oobe] command of /etc/wsl-distribution.conf, so the
# first launch lands in a root login shell with no owner account. This hook
# runs the OOBE there and then switches the session to the new owner (uid 1000).
#
# It acts only when ALL of these hold, and is inert otherwise:
#   - root interactive login shell (profile.d is read by login shells only);
#   - stdin and stdout are terminals;
#   - the OOBE sentinel /var/lib/omarchy/oobe_completed is absent;
#   - root was not entered from another account: SUDO_USER is unset and no
#     ancestor process has a non-root real uid (sudo -i, su -, runuser).
# The OOBE takes the shared account lock itself, so this cannot interleave with
# WSL's own OOBE or omarchy-rename-owner (it exits 75 when busy).
#
# POSIX sh only: sourced by bash, by sh and by zsh (emulate sh) login shells.
# ==============================================================================

_omarchy_firstboot() {
  [ "$(id -u 2>/dev/null)" = 0 ] || return 0
  [ -e /var/lib/omarchy/oobe_completed ] && return 0
  case $- in
    *i*) ;;
    *) return 0 ;;
  esac
  { [ -t 0 ] && [ -t 1 ]; } || return 0
  [ -z "${SUDO_USER:-}" ] || return 0

  # Walk up the process tree: any ancestor with a non-root real uid means this
  # root shell was opened from another account (su/sudo/runuser keep the
  # caller's real uid in their own process).
  _ofb_pid=$PPID
  _ofb_n=0
  while [ "${_ofb_pid:-0}" -gt 1 ] && [ "$_ofb_n" -lt 32 ]; do
    _ofb_ruid=$(sed -n 's/^Uid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "/proc/$_ofb_pid/status" 2>/dev/null)
    [ -n "$_ofb_ruid" ] || break
    [ "$_ofb_ruid" = 0 ] || return 0
    _ofb_pid=$(sed -n 's/^PPid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "/proc/$_ofb_pid/status" 2>/dev/null)
    _ofb_n=$((_ofb_n + 1))
  done

  _ofb_oobe=""
  for _ofb_c in /usr/lib/wsl/oobe.sh /usr/lib/omarchy-wsl/oobe.sh; do
    if [ -x "$_ofb_c" ]; then
      _ofb_oobe=$_ofb_c
      break
    fi
  done
  [ -n "$_ofb_oobe" ] || return 0

  printf '\n[omarchy-wsl] First launch without the WSL OOBE (wsl --import): setting up your account.\n'
  "$_ofb_oobe"
  _ofb_rc=$?
  if [ "$_ofb_rc" -ne 0 ]; then
    printf '[omarchy-wsl] Setup did not finish (exit %s); it runs again at the next root login.\n' "$_ofb_rc" >&2
    return 0
  fi

  # The owner is whoever holds uid 1000, never a name from a file.
  _ofb_owner=$(getent passwd 1000 2>/dev/null | cut -d: -f1)
  [ -n "$_ofb_owner" ] || return 0
  printf '[omarchy-wsl] Switching this session to %s.\n' "$_ofb_owner"
  exec runuser -u "$_ofb_owner" -- bash -l
}

_omarchy_firstboot
unset -f _omarchy_firstboot 2>/dev/null
unset _ofb_pid _ofb_n _ofb_ruid _ofb_oobe _ofb_c _ofb_rc _ofb_owner
