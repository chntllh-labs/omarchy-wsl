#!/bin/sh
# /etc/profile.d/30-omarchy-ssh-agent.sh
# Points SSH_AUTH_SOCK at the Windows agent bridge when it is available.
# Never overrides a live agent (e.g. one forwarded by `ssh -A`).
# The bridge listens on $XDG_RUNTIME_DIR/ssh-agent.sock, or on
# ~/.cache/omarchy/run/ssh-agent.sock when there is no private runtime dir
# (never a /tmp path). systemd --user services get the same variable from
# environment.d, written by `omarchy-ssh-agent-bridge enable`.
if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "${SSH_AUTH_SOCK}" ]; then
  _omarchy_conf="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ssh-agent-bridge.conf"
  if [ -r "$_omarchy_conf" ] && grep -q '^OMARCHY_SSH_AGENT_BRIDGE=1' "$_omarchy_conf" 2>/dev/null \
     && [ -x /usr/lib/omarchy-wsl/bin/omarchy-ssh-agent-bridge ]; then
    # Idempotent: returns at once when the bridge is already running.
    /usr/lib/omarchy-wsl/bin/omarchy-ssh-agent-bridge start --quiet >/dev/null 2>&1 || true
  fi
  for _omarchy_sock in "${XDG_RUNTIME_DIR:-/nonexistent}/ssh-agent.sock" \
                       "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/run/ssh-agent.sock"; do
    # Only a socket this user owns (test -O is not POSIX sh).
    if [ -S "$_omarchy_sock" ] && [ "$(stat -c %u "$_omarchy_sock" 2>/dev/null)" = "$(id -u)" ]; then
      export SSH_AUTH_SOCK="$_omarchy_sock"
      break
    fi
  done
  unset _omarchy_conf _omarchy_sock
fi
