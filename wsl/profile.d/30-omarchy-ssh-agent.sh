#!/bin/sh
# /etc/profile.d/30-omarchy-ssh-agent.sh
# Points SSH_AUTH_SOCK at the Windows agent bridge when it is available.
# Never overrides a live agent (e.g. one forwarded by `ssh -A`).
_omarchy_bridge_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.sock"

if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "${SSH_AUTH_SOCK}" ]; then
  _omarchy_conf="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/ssh-agent-bridge.conf"
  if [ ! -S "$_omarchy_bridge_sock" ] && [ -r "$_omarchy_conf" ] \
     && grep -q '^OMARCHY_SSH_AGENT_BRIDGE=1' "$_omarchy_conf" 2>/dev/null \
     && [ -x /usr/lib/omarchy-wsl/bin/omarchy-ssh-agent-bridge ]; then
    /usr/lib/omarchy-wsl/bin/omarchy-ssh-agent-bridge start --quiet >/dev/null 2>&1 || true
  fi
  if [ -S "$_omarchy_bridge_sock" ]; then
    export SSH_AUTH_SOCK="$_omarchy_bridge_sock"
  fi
  unset _omarchy_conf
fi
unset _omarchy_bridge_sock
