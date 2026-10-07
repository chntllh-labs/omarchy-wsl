#!/bin/sh
# /etc/profile.d/40-omarchy-drvfs-guard.sh
# Loads the DrvFs performance boundary guard into interactive bash/zsh shells.
# For non-login interactive shells, add to ~/.bashrc:
#   . /usr/lib/omarchy-wsl/drvfs-guard.sh
if [ -r /usr/lib/omarchy-wsl/drvfs-guard.sh ]; then
  . /usr/lib/omarchy-wsl/drvfs-guard.sh
fi
