#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Shared Common Library (logging, config parsing, atomic files)
# /usr/lib/omarchy-wsl/common.sh
# ==============================================================================
# Sourced (never executed) by the root/admin tools that do not need Windows
# interop: oobe.sh (via account.sh), omarchy-rename-owner, omarchy-tenant.
#
# Conventions (docs/OOBE-SPECIFICATION.md, docs/MULTI-TENANT-ISOLATION.md):
# 1. Logs go to stderr, tag-prefixed; data goes to stdout.
# 2. Colour only when stderr is a terminal and NO_COLOR is unset or empty
#    (https://no-color.org). TERM=dumb also disables colour.
# 3. Messages are printed with printf %s (no escape interpretation) and any
#    Tailscale auth key (tskey-...) is masked before it reaches a terminal or
#    a log file.
# 4. Configuration files are parsed with a whitelist reader, never sourced.
# 5. Files are replaced atomically (temp file in the same directory + rename).
#
# Portability: this file and account.sh stay compatible with bash 3.2 so the
# unit tests run unchanged on macOS. No associative arrays, no ${x,,}, and
# every possibly-empty array is expanded as ${a[@]+"${a[@]}"} (set -u safe).
#
# Test seams:
#   OMARCHY_SYSTEMD_RUNNING=1|0   force "systemd is PID 1" detection
#   OMW_QUIET=1                   silence omw_log (warnings/errors still print)
# ==============================================================================

# Guard against double-sourcing.
[[ -n "${_OMW_COMMON_LOADED:-}" ]] && return 0
_OMW_COMMON_LOADED=1

OMW_TAG="${OMW_TAG:-omarchy}"

# -----------------------------------------------------------------------------
# 1. Colour & logging
# -----------------------------------------------------------------------------
# OMW_C_* are part of the library API (callers colour their own output).
# shellcheck disable=SC2034
omw_color_init() {
  if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    OMW_C_RESET=$'\033[0m'
    OMW_C_BOLD=$'\033[1m'
    OMW_C_RED=$'\033[31m'
    OMW_C_GREEN=$'\033[32m'
    OMW_C_YELLOW=$'\033[33m'
    OMW_C_CYAN=$'\033[36m'
  else
    OMW_C_RESET="" OMW_C_BOLD="" OMW_C_RED="" OMW_C_GREEN="" OMW_C_YELLOW="" OMW_C_CYAN=""
  fi
}
omw_color_init

# _omw_redact <text> -> REPLY (no subshell). Masks Tailscale auth keys.
_omw_redact() {
  local s="$1" out="" body
  while [[ "$s" == *tskey-* ]]; do
    out="${out}${s%%tskey-*}tskey-****"
    s="${s#*tskey-}"
    body="${s%%[!A-Za-z0-9_-]*}"
    s="${s#"$body"}"
  done
  REPLY="${out}${s}"
}

# omw_redact <text> -> stdout. Use in pipelines: cmd 2>&1 | omw_redact_stream
omw_redact() {
  _omw_redact "$1"
  printf '%s\n' "$REPLY"
}

omw_redact_stream() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    _omw_redact "$line"
    printf '%s\n' "$REPLY"
  done
}

_omw_emit() {
  local color="$1" tag="$2" msg="$3"
  if [[ "$msg" == *tskey-* ]]; then
    _omw_redact "$msg"
    msg="$REPLY"
  fi
  printf '%s%s%s %s\n' "$color" "$tag" "$OMW_C_RESET" "$msg" >&2
}

omw_log()  { [[ -n "${OMW_QUIET:-}" ]] && return 0; _omw_emit "$OMW_C_GREEN" "[${OMW_TAG}]" "$*"; }
omw_step() { [[ -n "${OMW_QUIET:-}" ]] && return 0; _omw_emit "$OMW_C_CYAN" "[${OMW_TAG}]" "$*"; }
omw_warn() { _omw_emit "$OMW_C_YELLOW" "[${OMW_TAG}:WARN]" "$*"; }
omw_err()  { _omw_emit "$OMW_C_RED" "[${OMW_TAG}:ERROR]" "$*"; }
omw_die()  { omw_err "$*"; exit 1; }
# omw_fail <exit-code> <message...>
omw_fail() { local rc="$1"; shift; omw_err "$*"; exit "$rc"; }

omw_have() { command -v "$1" >/dev/null 2>&1; }

omw_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# True when systemd is PID 1 (sd_booted() semantics: /run/systemd/system).
omw_systemd_running() {
  case "${OMARCHY_SYSTEMD_RUNNING:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -d /run/systemd/system ]]
}

# True when a controlling terminal can actually be opened (an existing
# /dev/tty node is not enough: open() fails with ENXIO without a ctty).
omw_have_tty() {
  [[ -n "${OMARCHY_NO_TTY:-}" ]] && return 1
  { : </dev/tty; } 2>/dev/null
}

# -----------------------------------------------------------------------------
# 2. Whitelist key=value reader / writer (never `source` a config file)
# -----------------------------------------------------------------------------
# Accepted syntax: KEY=VALUE, KEY="VALUE", KEY='VALUE', blank lines and full-line
# # comments. No expansion, no escapes, no inline comments. The last assignment
# of a key wins. Callers must validate the returned value against their own
# whitelist regex before using it.

# omw_kv_get <file> <KEY> -> prints the value; returns 1 if absent/unreadable.
omw_kv_get() {
  local file="$1" want="$2" line key val found=1
  local re='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'
  local dq='^"(.*)"$' sq="^'(.*)'$"
  [[ -r "$file" && -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $re ]] || continue
    key="${BASH_REMATCH[1]}"
    [[ "$key" == "$want" ]] || continue
    val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ $dq ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ $sq ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    REPLY="$val"
    found=0
  done <"$file"
  (( found == 0 )) || return 1
  printf '%s\n' "$REPLY"
}

# A value the writer accepts: printable, no quote/backslash/dollar/backtick.
omw_kv_value_ok() {
  local re='^[A-Za-z0-9_./:@,+=% -]*$'
  [[ "$1" =~ $re ]]
}

# omw_kv_render <file> <KEY> <VALUE> -> stdout: the file with KEY set (all
# previous assignments of KEY dropped, the new one placed where the first one
# was, or appended). Comments and other keys are preserved byte for byte.
omw_kv_render() {
  local file="$1" want="$2" value="$3" line key done=0 out
  local re='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*='
  if [[ "$value" == *" "* || -z "$value" ]]; then
    out="${want}=\"${value}\""
  else
    out="${want}=${value}"
  fi
  if [[ -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $re ]]; then
        key="${BASH_REMATCH[1]}"
        if [[ "$key" == "$want" ]]; then
          if (( done == 0 )); then
            printf '%s\n' "$out"
            done=1
          fi
          continue
        fi
      fi
      printf '%s\n' "$line"
    done <"$file"
  fi
  (( done == 1 )) || printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
# 3. Atomic file replacement & temp-file bookkeeping
# -----------------------------------------------------------------------------
# Temp files created through omw_mktemp_beside are removed by omw_cleanup_tmp,
# which callers run from their EXIT/signal traps.
OMW_TMP_FILES=()

omw_cleanup_tmp() {
  local f
  for f in ${OMW_TMP_FILES[@]+"${OMW_TMP_FILES[@]}"}; do
    [[ -n "$f" && ( -f "$f" || -L "$f" ) ]] && rm -f -- "$f" 2>/dev/null
  done
  OMW_TMP_FILES=()
  return 0
}

# omw_mktemp_beside <dest> -> prints a new temp path in dest's directory. The
# name starts with "." and contains a "." so sudo's @includedir and most
# *.d directory readers ignore it if it is ever left behind.
omw_mktemp_beside() {
  local dest="$1" dir base tmp
  dir="$(dirname -- "$dest")"
  base="$(basename -- "$dest")"
  tmp="$(mktemp "${dir}/.${base}.omw.XXXXXX")" || return 1
  OMW_TMP_FILES+=("$tmp")
  printf '%s\n' "$tmp"
}

# omw_atomic_write <dest> <mode> [owner] < content
# Writes stdin to a temp file beside <dest>, applies mode/owner, renames it over
# <dest>. chown failures are fatal only when running as root (tests run the
# same code unprivileged against sandbox paths).
omw_atomic_write() {
  local dest="$1" mode="$2" owner="${3:-}" tmp
  # mv(1) would move the temp file INTO a directory (or a symlink to one)
  # instead of replacing it; refuse that portably (no GNU-only mv -T).
  if [[ -d "$dest" ]]; then
    omw_err "refusing to replace $dest: it is a directory (or a symlink to one)"
    return 1
  fi
  tmp="$(omw_mktemp_beside "$dest")" || { omw_err "cannot create a temp file beside $dest"; return 1; }
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    omw_err "cannot write $tmp"
    return 1
  fi
  chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [[ -n "$owner" ]]; then
    if ! chown "$owner" "$tmp" 2>/dev/null && omw_is_root; then
      rm -f -- "$tmp"
      omw_err "cannot chown $tmp to $owner"
      return 1
    fi
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    omw_err "cannot rename $tmp over $dest"
    return 1
  fi
  return 0
}

# omw_kv_set <file> <KEY> <VALUE> [mode] [owner] — atomic key update.
omw_kv_set() {
  local file="$1" key="$2" value="$3" mode="${4:-0644}" owner="${5:-}"
  local kre='^[A-Za-z_][A-Za-z0-9_]*$'
  [[ "$key" =~ $kre ]] || { omw_err "invalid config key: $key"; return 2; }
  omw_kv_value_ok "$value" || { omw_err "refusing to write an unsafe value for $key"; return 2; }
  omw_kv_render "$file" "$key" "$value" | omw_atomic_write "$file" "$mode" "$owner"
}

# -----------------------------------------------------------------------------
# 4. Locking (flock on a dedicated fd; fd 9 is reserved for this)
# -----------------------------------------------------------------------------
# omw_lock_acquire <lockfile> -> 0 locked, 75 busy (EX_TEMPFAIL), 1 error.
# Long-lived children must be started with 9>&- so they do not inherit it.
omw_lock_acquire() {
  local file="$1"
  if ! omw_have flock; then
    omw_warn "flock(1) is not installed; continuing without a lock."
    return 0
  fi
  if [[ -L "$file" ]]; then
    omw_err "lock file $file is a symlink; refusing."
    return 1
  fi
  if [[ ! -d "$(dirname -- "$file")" ]]; then
    omw_err "lock directory for $file does not exist."
    return 1
  fi
  exec 9>>"$file" || { omw_err "cannot open lock file $file"; return 1; }
  flock -n 9 || return 75
  return 0
}

omw_lock_release() {
  exec 9>&- 2>/dev/null || true
}
