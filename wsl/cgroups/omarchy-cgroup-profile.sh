#!/bin/sh
# /etc/profile.d/60-omarchy-cgroup-governance.sh
# Omarchy-WSL memory-safe build defaults for login shells.
# Exports CARGO_BUILD_JOBS, MAKEFLAGS and CMAKE_BUILD_PARALLEL_LEVEL only when
# they are unset, sized min(CPUs, RAM GiB / 2) (at least 2) so a high-core,
# low-RAM machine does not OOM while linking. omarchy-build computes its own
# value per build (and applies the power governor); this is the baseline for
# plain `make`/`cargo` runs.

if [ -z "${CARGO_BUILD_JOBS:-}" ] || [ -z "${MAKEFLAGS:-}" ] || [ -z "${CMAKE_BUILD_PARALLEL_LEVEL:-}" ]; then
  _omarchy_cpus=$(nproc 2>/dev/null || echo 2)
  _omarchy_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 8388608)
  _omarchy_safe=$(( _omarchy_mem_kb / 1024 / 1024 / 2 ))
  [ "$_omarchy_safe" -lt 2 ] && _omarchy_safe=2

  if [ "$_omarchy_cpus" -lt "$_omarchy_safe" ]; then
    _omarchy_jobs="$_omarchy_cpus"
  else
    _omarchy_jobs="$_omarchy_safe"
  fi

  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_omarchy_jobs}"
  export MAKEFLAGS="${MAKEFLAGS:--j$_omarchy_jobs}"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$_omarchy_jobs}"
  unset _omarchy_cpus _omarchy_mem_kb _omarchy_safe _omarchy_jobs
fi
