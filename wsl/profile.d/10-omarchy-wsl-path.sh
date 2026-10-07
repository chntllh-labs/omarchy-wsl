#!/bin/sh
# /etc/profile.d/10-omarchy-wsl-path.sh
# Safely exposes curated Windows interop shims without PATH contamination.
if [ -d "/usr/lib/omarchy-wsl/bin" ]; then
  case ":${PATH}:" in
    *:/usr/lib/omarchy-wsl/bin:*) ;;
    *) export PATH="${PATH}:/usr/lib/omarchy-wsl/bin" ;;
  esac
fi
