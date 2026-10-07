#!/bin/sh
# /etc/profile.d/20-omarchy-browser.sh
# Route $BROWSER consumers (gh, npm login, python -m webbrowser, jupyter, cargo
# doc --open, ...) to the hardened Windows launcher instead of wslview.
if [ -z "${BROWSER:-}" ] && [ -n "${WSL_DISTRO_NAME:-}" ] && command -v omarchy-open >/dev/null 2>&1; then
  export BROWSER=omarchy-open
fi
