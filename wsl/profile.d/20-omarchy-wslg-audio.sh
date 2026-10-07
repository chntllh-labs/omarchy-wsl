#!/bin/sh
# /etc/profile.d/20-omarchy-wslg-audio.sh
# Default PulseAudio client buffer for WSLg sessions (see environment.d for
# systemd user services). Only applied when the WSLg server is present.
if [ -S /mnt/wslg/PulseServer ]; then
  : "${PULSE_SERVER:=unix:/mnt/wslg/PulseServer}"
  : "${PULSE_LATENCY_MSEC:=60}"
  export PULSE_SERVER PULSE_LATENCY_MSEC
fi
