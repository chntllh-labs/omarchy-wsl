#!/bin/sh
# /etc/profile.d/omarchy-cgroup-governance.sh
# Omarchy-WSL Cgroup Governance & Safe Build Environment
# Transparently sets memory-safe build defaults and provides omarchy-build aliases.

# Auto-compute safe build jobs if not already set by the user
if [ -z "${CARGO_BUILD_JOBS:-}" ] || [ -z "${MAKEFLAGS:-}" ]; then
  _cpus=$(nproc 2>/dev/null || echo 2)
  _mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 8388608)
  _mem_gb=$(( _mem_kb / 1024 / 1024 ))
  _safe_jobs=$(( _mem_gb / 2 ))
  [ "$_safe_jobs" -lt 2 ] && _safe_jobs=2

  if [ "$_cpus" -lt "$_safe_jobs" ]; then
    _jobs="$_cpus"
  else
    _jobs="$_safe_jobs"
  fi

  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_jobs}"
  export MAKEFLAGS="${MAKEFLAGS:--j$_jobs}"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$_jobs}"
  unset _cpus _mem_kb _mem_gb _safe_jobs _jobs
fi
