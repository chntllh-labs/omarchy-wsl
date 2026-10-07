#!/bin/sh
# /etc/profile.d/50-omarchy-docker.sh
# Exports DOCKER_HOST for the engine chosen with `omarchy-docker-bridge use`.
# Opt-in only: without ~/.config/omarchy/docker-bridge.conf nothing is set,
# so `docker context` and Docker Desktop's own socket keep working untouched.
if [ -z "${DOCKER_HOST:-}" ] \
   && [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/docker-bridge.conf" ] \
   && command -v omarchy-docker-bridge >/dev/null 2>&1; then
  eval "$(omarchy-docker-bridge env 2>/dev/null)"
fi
