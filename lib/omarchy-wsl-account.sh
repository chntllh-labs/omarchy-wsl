#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Shared Owner-Account Library (uid 1000)
# /usr/lib/omarchy-wsl/account.sh
# ==============================================================================
# Sourced (never executed) by /usr/lib/wsl/oobe.sh, /usr/bin/omarchy-rename-owner
# and the test suites, so the code that runs on a user's machine is the code
# the tests exercise.
#
# Identity rule: the distro owner is whoever holds uid 1000 (`getent passwd
# 1000`). Names recorded in the sentinel or /etc/omarchy-user.conf are
# informational and never used to decide who the owner is.
#
# Safety rules:
# - Sudoers drop-ins contain ONLY the owner rule, are validated with
#   `visudo -cf` before they are moved into place, and never grant %wheel
#   passwordless root.
# - Every file is replaced atomically (temp file in the same directory + mv).
# - Usernames are transliterated with an explicit table (identical on glibc,
#   musl and macOS); no iconv //TRANSLIT, which depends on the locale.
# - Configuration is read with a whitelist parser, never sourced.
#
# Portability: bash 3.2 compatible (the unit tests also run on macOS).
#
# Test seams (all default to the real system paths):
#   OMARCHY_SENTINEL_DIR   /var/lib/omarchy          (sentinel, journals)
#   OMARCHY_USER_CONF      /etc/omarchy-user.conf
#   OMARCHY_USER_CONF_TEMPLATE  /usr/share/omarchy-wsl/omarchy-user.conf.default
#   OMARCHY_WSL_CONF       /etc/wsl.conf
#   OMARCHY_SUDOERS_DIR    /etc/sudoers.d
#   OMARCHY_SUDOERS_MAIN   /etc/sudoers
#   OMARCHY_LINGER_DIR     /var/lib/systemd/linger
#   OMARCHY_PASSWD_ROOT    unset = NSS via getent; <dir> = read <dir>/etc/{passwd,group}
#   OMARCHY_HOME_ROOT      /home
#   OMARCHY_SKEL_DIR       /etc/skel
#   OMARCHY_LOCK_FILE      /run/omarchy/account.lock
#   OMARCHY_TENANT_ROOT    /var/lib/omarchy/tenants  (names a tenant already uses)
#   OMARCHY_TRANSLIT       auto | table  (table = never call python3)
#   OMARCHY_NOW            fixed timestamp for the sentinel (reproducible tests)
# ==============================================================================

[[ -n "${_OMW_ACCOUNT_LOADED:-}" ]] && return 0
_OMW_ACCOUNT_LOADED=1

if ! declare -F omw_log >/dev/null 2>&1; then
  _omw_acct_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _omw_acct_c in "$_omw_acct_here/omarchy-wsl-common.sh" "$_omw_acct_here/common.sh"; do
    # shellcheck source=SCRIPTDIR/omarchy-wsl-common.sh
    if [[ -r "$_omw_acct_c" ]]; then source "$_omw_acct_c"; break; fi
  done
  unset _omw_acct_here _omw_acct_c
fi
declare -F omw_log >/dev/null 2>&1 || { echo "account.sh: common library (common.sh) not found" >&2; return 1; }

OMW_OWNER_UID=1000
OMW_FALLBACK_USER="omarchy"
OMW_ACCT_VERSION="2.0.0"
OMW_ACCT_REASON=""
OMW_MANAGED_MARKER="# Managed by omarchy-wsl (account.sh): distro owner rule only."

# (Re)read the seams. Tests call this again after changing the environment.
# The OMW_* variables are library API used by oobe.sh and omarchy-rename-owner.
# shellcheck disable=SC2034
omw_acct_init() {
  OMW_SENTINEL_DIR="${OMARCHY_SENTINEL_DIR:-/var/lib/omarchy}"
  OMW_SENTINEL_FILE="${OMW_SENTINEL_DIR}/oobe_completed"
  OMW_USER_CONF="${OMARCHY_USER_CONF:-/etc/omarchy-user.conf}"
  OMW_USER_CONF_TEMPLATE="${OMARCHY_USER_CONF_TEMPLATE:-/usr/share/omarchy-wsl/omarchy-user.conf.default}"
  OMW_WSL_CONF="${OMARCHY_WSL_CONF:-/etc/wsl.conf}"
  OMW_SUDOERS_DIR="${OMARCHY_SUDOERS_DIR:-/etc/sudoers.d}"
  OMW_SUDOERS_MAIN="${OMARCHY_SUDOERS_MAIN:-/etc/sudoers}"
  OMW_LINGER_DIR="${OMARCHY_LINGER_DIR:-/var/lib/systemd/linger}"
  OMW_PASSWD_ROOT="${OMARCHY_PASSWD_ROOT:-}"
  OMW_HOME_ROOT="${OMARCHY_HOME_ROOT:-/home}"
  OMW_SKEL_DIR="${OMARCHY_SKEL_DIR:-/etc/skel}"
  OMW_LOCK_FILE="${OMARCHY_LOCK_FILE:-/run/omarchy/account.lock}"
  OMW_TENANT_ROOT="${OMARCHY_TENANT_ROOT:-/var/lib/omarchy/tenants}"
}
omw_acct_init

# _omw_ensure_dir <mode> <dir> — create (with parents) and set the mode of the
# leaf only when it does not exist yet; never changes an existing directory.
_omw_ensure_dir() {
  [[ -d "$2" ]] && return 0
  mkdir -p -- "$2" && chmod "$1" -- "$2"
}

# chown that is fatal only for root (tests run unprivileged against sandboxes).
_omw_chown() {
  if chown "$@" 2>/dev/null; then return 0; fi
  if omw_is_root; then
    omw_err "chown $* failed"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# 1. Transliteration & sanitizing ("suggest" mode for detected Windows names)
# -----------------------------------------------------------------------------
# Latin-1 Supplement + Latin Extended-A (+ a few Extended-B letters), both cases.
# Generated from Unicode NFKD and checked for equality with it; letters NFKD
# cannot decompose are mapped explicitly (ß->ss, æ->ae, ø->o, ł->l, đ->d, ...).
_OMW_TRANSLIT_TABLE=(
  "À A" "Á A" "Â A" "Ã A" "Ä A" "Å A" "Æ AE" "Ç C" "È E" "É E" "Ê E" "Ë E"
  "Ì I" "Í I" "Î I" "Ï I" "Ð D" "Ñ N" "Ò O" "Ó O" "Ô O" "Õ O" "Ö O" "Ø O"
  "Ù U" "Ú U" "Û U" "Ü U" "Ý Y" "Þ TH" "ß ss" "à a" "á a" "â a" "ã a" "ä a"
  "å a" "æ ae" "ç c" "è e" "é e" "ê e" "ë e" "ì i" "í i" "î i" "ï i" "ð d"
  "ñ n" "ò o" "ó o" "ô o" "õ o" "ö o" "ø o" "ù u" "ú u" "û u" "ü u" "ý y"
  "þ th" "ÿ y" "Ā A" "ā a" "Ă A" "ă a" "Ą A" "ą a" "Ć C" "ć c" "Ĉ C" "ĉ c"
  "Ċ C" "ċ c" "Č C" "č c" "Ď D" "ď d" "Đ D" "đ d" "Ē E" "ē e" "Ĕ E" "ĕ e"
  "Ė E" "ė e" "Ę E" "ę e" "Ě E" "ě e" "Ĝ G" "ĝ g" "Ğ G" "ğ g" "Ġ G" "ġ g"
  "Ģ G" "ģ g" "Ĥ H" "ĥ h" "Ħ H" "ħ h" "Ĩ I" "ĩ i" "Ī I" "ī i" "Ĭ I" "ĭ i"
  "Į I" "į i" "İ I" "ı i" "Ĳ IJ" "ĳ ij" "Ĵ J" "ĵ j" "Ķ K" "ķ k" "ĸ k" "Ĺ L"
  "ĺ l" "Ļ L" "ļ l" "Ľ L" "ľ l" "Ŀ L" "ŀ l" "Ł L" "ł l" "Ń N" "ń n" "Ņ N"
  "ņ n" "Ň N" "ň n" "ŉ n" "Ŋ N" "ŋ n" "Ō O" "ō o" "Ŏ O" "ŏ o" "Ő O" "ő o"
  "Œ OE" "œ oe" "Ŕ R" "ŕ r" "Ŗ R" "ŗ r" "Ř R" "ř r" "Ś S" "ś s" "Ŝ S" "ŝ s"
  "Ş S" "ş s" "Š S" "š s" "Ţ T" "ţ t" "Ť T" "ť t" "Ŧ T" "ŧ t" "Ũ U" "ũ u"
  "Ū U" "ū u" "Ŭ U" "ŭ u" "Ů U" "ů u" "Ű U" "ű u" "Ų U" "ų u" "Ŵ W" "ŵ w"
  "Ŷ Y" "ŷ y" "Ÿ Y" "Ź Z" "ź z" "Ż Z" "ż z" "Ž Z" "ž z" "ſ s" "Ə E" "ə e"
  "ƒ f" "Ș S" "ș s" "Ț T" "ț t"
)

# NFKD + ASCII filter for characters outside the table (e.g. Vietnamese).
# Invalid UTF-8 decodes to U+FFFD and is dropped, so the output is pure ASCII.
_OMW_NFKD_PY='import sys, unicodedata
s = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.stdout.write("".join(c for c in unicodedata.normalize("NFKD", s) if ord(c) < 128))'

# _omw_translit <text> -> REPLY (ASCII only)
_omw_translit() {
  local s="$1" pair from to ascii out
  for pair in "${_OMW_TRANSLIT_TABLE[@]}"; do
    from="${pair%% *}"
    [[ "$s" == *"$from"* ]] || continue
    to="${pair#* }"
    s="${s//"$from"/$to}"
  done
  ascii="$(printf '%s' "$s" | LC_ALL=C tr -d '\200-\377')"
  if [[ "$ascii" != "$s" ]]; then
    # python3 -I: isolated mode (no cwd on sys.path, no PYTHON* variables), so
    # running the OOBE from a writable directory cannot import planted modules.
    if [[ "${OMARCHY_TRANSLIT:-auto}" != "table" ]] && omw_have python3 \
       && out="$(printf '%s' "$s" | python3 -I -S -c "$_OMW_NFKD_PY" 2>/dev/null)"; then
      s="$out"
    else
      s="$ascii"
    fi
  fi
  REPLY="$s"
}

# sanitize_username <raw> -> stdout. Always prints a name that matches the
# strict shape (falls back to "omarchy" when nothing usable is left, e.g. an
# all-Cyrillic or all-CJK Windows name). Does NOT check reserved names or the
# account database; see suggest_username for that.
sanitize_username() {
  local s
  _omw_translit "${1:-}"
  s="$(printf '%s' "$REPLY" | LC_ALL=C tr -d '\r\n' | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' \
      | LC_ALL=C sed -E -e 's/[^a-z0-9_-]+/_/g' -e 's/[-_]*_[-_]*/_/g' -e 's/-+/-/g' -e 's/^[-_]+//' -e 's/[-_]+$//')"
  case "$s" in
    [0-9]*) s="u_${s}" ;;
  esac
  s="${s:0:31}"
  while [[ "$s" == *[-_] ]]; do s="${s%?}"; done
  if ! _omw_name_shape_ok "$s"; then
    s="$OMW_FALLBACK_USER"
  fi
  printf '%s\n' "$s"
}

# -----------------------------------------------------------------------------
# 2. Strict validation ("reject" mode for --user / rename)
# -----------------------------------------------------------------------------
# Explicit character lists: [a-z] ranges in bash regexes follow the locale's
# collation and may match uppercase or accented letters in some locales.
_OMW_RE_NAME='^[abcdefghijklmnopqrstuvwxyz_][abcdefghijklmnopqrstuvwxyz0123456789_-]*$'

_omw_name_shape_ok() {
  [[ -n "$1" && ${#1} -le 31 && "$1" =~ $_OMW_RE_NAME ]]
}

# System accounts and groups shipped by Arch/ALARM, Debian/Ubuntu and common
# packages. Names here are never given to the owner even if absent locally.
_OMW_RESERVED_NAMES=" root bin daemon adm lp sync shutdown halt mail news uucp operator games ftp
 nobody nogroup sys tty disk kmem dialout fax voice cdrom floppy tape sudo audio dip www-data
 backup list irc src gnats shadow utmp video sasl plugdev staff users wheel log locate network
 power rfkill storage optical scanner input kvm render sgx docker dbus polkitd polkit rtkit avahi
 colord git http uuidd tss sshd ntp chrony alpm usbmux geoclue named postgres mysql messagebus
 lock man proxy systemd nm-openvpn nm-openconnect _apt tcpdump dnsmasq tailscale nginx admin "

_omw_reserved_name() {
  case "$_OMW_RESERVED_NAMES" in
    *" $1 "*) return 0 ;;
  esac
  case "$1" in
    systemd-*|_*) return 0 ;;
  esac
  return 1
}

# validate_username <name> -> 0 valid; 1 invalid with OMW_ACCT_REASON set.
# Pure (no account-database lookups): shape, length and reserved names.
# The documented shape is ^[a-z_][a-z0-9_-]{0,31}$, additionally capped at 31
# characters because systemd (and utmp) reject 32-character user names.
validate_username() {
  local name="${1:-}"
  OMW_ACCT_REASON=""
  if [[ -z "$name" ]]; then
    OMW_ACCT_REASON="the name is empty"
    return 1
  fi
  if [[ ${#name} -gt 31 ]]; then
    OMW_ACCT_REASON="'$name' is longer than 31 characters"
    return 1
  fi
  if ! [[ "$name" =~ $_OMW_RE_NAME ]]; then
    OMW_ACCT_REASON="'$name' must match ^[a-z_][a-z0-9_-]{0,31}\$ (lowercase ASCII letters, digits, '_' and '-'; no leading digit or '-')"
    return 1
  fi
  if _omw_reserved_name "$name"; then
    OMW_ACCT_REASON="'$name' is a reserved system account or group name"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# 3. Account database access (NSS, or a sandbox passwd/group for tests)
# -----------------------------------------------------------------------------
# omw_getent <passwd|group|shadow> <name-or-id> -> the entry; 2 if not found.
omw_getent() {
  local db="$1" key="$2" file
  if [[ -n "$OMW_PASSWD_ROOT" ]]; then
    file="$OMW_PASSWD_ROOT/etc/$db"
    [[ -r "$file" ]] || return 2
    awk -F: -v k="$key" '($1 "" == k "") || ($3 "" == k "") { print; found = 1; exit } END { exit found ? 0 : 2 }' "$file"
    # Never a bare `return` in this library: inside a trap handler (the
    # rollback of omarchy-rename-owner runs in one) it would return the status
    # of the command interrupted by the signal instead of awk's.
    return $?
  fi
  getent "$db" "$key"
}

# owner_name -> name of uid 1000; returns 1 when no account has uid 1000.
owner_name() {
  local ent
  ent="$(omw_getent passwd "$OMW_OWNER_UID" 2>/dev/null)" || return 1
  [[ -n "$ent" ]] || return 1
  printf '%s\n' "${ent%%:*}"
}

# _omw_passwd_field <name-or-uid> <field-number>
_omw_passwd_field() {
  local ent
  ent="$(omw_getent passwd "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$ent" | cut -d: -f"$2"
}

owner_home() { _omw_passwd_field "$OMW_OWNER_UID" 6; }

omw_user_exists()  { omw_getent passwd "$1" >/dev/null 2>&1; }
omw_group_exists() { omw_getent group "$1" >/dev/null 2>&1; }
omw_group_gid()    { local e; e="$(omw_getent group "$1" 2>/dev/null)" || return 1; printf '%s\n' "$e" | cut -d: -f3; }

# omw_name_conflict <name> [rename] -> 0 if <name> can NOT be given to uid 1000
# (OMW_ACCT_REASON says why). "rename" also refuses an existing /home/<name>
# and a tenant of the same name.
omw_name_conflict() {
  local name="$1" mode="${2:-create}" uid gid
  OMW_ACCT_REASON=""
  if omw_user_exists "$name"; then
    uid="$(_omw_passwd_field "$name" 3)"
    if [[ "$uid" != "$OMW_OWNER_UID" ]]; then
      OMW_ACCT_REASON="user '$name' already exists with uid $uid"
      return 0
    fi
    if [[ "$mode" == "rename" ]]; then
      OMW_ACCT_REASON="'$name' is already the name of uid $OMW_OWNER_UID"
      return 0
    fi
  fi
  if omw_group_exists "$name"; then
    gid="$(omw_group_gid "$name")"
    # When creating the owner, an existing group of that name with gid 1000
    # is what `useradd -U` would have made: reuse it as the primary group.
    # Any other existing group is a collision (e.g. "games", "users").
    if ! [[ "$mode" == "create" && "$gid" == "$OMW_OWNER_UID" ]]; then
      OMW_ACCT_REASON="group '$name' already exists (gid $gid)"
      return 0
    fi
  fi
  if [[ "$mode" == "rename" ]]; then
    # The compatibility symlink of an earlier rename (pointing at the current
    # owner home) does not block renaming back; anything else does.
    if [[ -L "$OMW_HOME_ROOT/$name" && "$(readlink -- "$OMW_HOME_ROOT/$name")" == "$(owner_home 2>/dev/null)" ]]; then
      :
    elif [[ -e "$OMW_HOME_ROOT/$name" || -L "$OMW_HOME_ROOT/$name" ]]; then
      OMW_ACCT_REASON="$OMW_HOME_ROOT/$name already exists"
      return 0
    fi
    if [[ -e "$OMW_TENANT_ROOT/$name" ]]; then
      OMW_ACCT_REASON="'$name' is the name of an omarchy-tenant guest"
      return 0
    fi
  fi
  return 1
}

# suggest_username <raw> -> stdout: a valid, non-conflicting name for a new
# owner derived from a detected Windows name (never fails).
suggest_username() {
  local base cand
  base="$(sanitize_username "${1:-}")"
  for cand in "$base" "u_${base}" "$OMW_FALLBACK_USER" "user${OMW_OWNER_UID}"; do
    cand="${cand:0:31}"
    while [[ "$cand" == *[-_] ]]; do cand="${cand%?}"; done
    validate_username "$cand" || continue
    omw_name_conflict "$cand" create && continue
    printf '%s\n' "$cand"
    return 0
  done
  printf '%s\n' "user${OMW_OWNER_UID}"
}

# -----------------------------------------------------------------------------
# 4. Sudoers (owner-only drop-in, validated, atomic)
# -----------------------------------------------------------------------------
# sudoers_rule <name> <nopasswd|password>
sudoers_rule() {
  case "$2" in
    nopasswd) printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$1" ;;
    password) printf '%s ALL=(ALL:ALL) ALL\n' "$1" ;;
    *) return 2 ;;
  esac
}

# sudoers_mode_of <name> -> nopasswd | password | none (no managed drop-in)
sudoers_mode_of() {
  local f="$OMW_SUDOERS_DIR/10-$1"
  [[ -f "$f" ]] || { echo none; return 0; }
  if grep -Eq "^[[:space:]]*$1[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:" "$f" 2>/dev/null; then
    echo nopasswd
  else
    echo password
  fi
}

# Make sure the main sudoers file includes the drop-in directory. The append is
# done on a copy, validated with visudo, then renamed into place; afterwards the
# live configuration is re-checked and the original restored on failure.
_omw_sudoers_ensure_includedir() {
  local main="$OMW_SUDOERS_MAIN" dir="$OMW_SUDOERS_DIR" tmp backup
  [[ -f "$main" ]] || { omw_warn "$main not found; cannot verify that $dir is included."; return 0; }
  if grep -Eq "^[[:space:]]*[@#]includedir[[:space:]]+${dir}/?[[:space:]]*$" "$main" 2>/dev/null; then
    return 0
  fi
  omw_step "Adding '@includedir $dir' to $main"
  tmp="$(omw_mktemp_beside "$main")" || return 1
  backup="$(omw_mktemp_beside "$main")" || return 1
  cp -p -- "$main" "$backup" || return 1
  { cat -- "$main"; printf '\n## Added by omarchy-wsl: owner drop-ins\n@includedir %s\n' "$dir"; } >"$tmp" || return 1
  chmod 0440 "$tmp"
  _omw_chown root:root "$tmp" || return 1
  if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
    omw_err "visudo rejected $main with the @includedir line; leaving it unchanged."
    rm -f -- "$tmp" "$backup"
    return 1
  fi
  mv -f -- "$tmp" "$main" || return 1
  if ! visudo -cqf "$main" >/dev/null 2>&1; then
    omw_err "visudo check failed after updating $main; restoring the original."
    mv -f -- "$backup" "$main"
    return 1
  fi
  rm -f -- "$backup"
  return 0
}

# configure_sudoers <owner> <nopasswd|password>
# Writes $OMW_SUDOERS_DIR/10-<owner> containing only the owner rule.
# Returns 3 when visudo is unavailable (nothing written: an unvalidated sudoers
# file can lock everyone out of sudo).
configure_sudoers() {
  local owner="$1" mode="${2:-nopasswd}" dest tmp
  validate_username "$owner" || { omw_err "sudoers: $OMW_ACCT_REASON"; return 2; }
  sudoers_rule "$owner" "$mode" >/dev/null || { omw_err "sudoers: unknown mode '$mode'"; return 2; }
  if ! omw_have visudo; then
    omw_warn "visudo not found (is sudo installed?); not writing an unvalidated sudoers drop-in."
    return 3
  fi
  if [[ ! -d "$OMW_SUDOERS_DIR" ]]; then
    _omw_ensure_dir 0750 "$OMW_SUDOERS_DIR" || return 1
  fi
  dest="$OMW_SUDOERS_DIR/10-$owner"
  tmp="$(omw_mktemp_beside "$dest")" || return 1
  {
    printf '%s\n' "$OMW_MANAGED_MARKER"
    printf '# Change with: omarchy-rename-owner (rename) or re-run the OOBE with --force.\n'
    sudoers_rule "$owner" "$mode"
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0440 "$tmp" || { rm -f -- "$tmp"; return 1; }
  _omw_chown root:root "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    omw_err "visudo rejected the generated drop-in for '$owner'; nothing installed."
    return 1
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  _omw_sudoers_ensure_includedir || return 1
  return 0
}

# remove_sudoers <name> — removes 10-<name> only if it carries our marker.
remove_sudoers() {
  local f="$OMW_SUDOERS_DIR/10-$1"
  validate_username "$1" || return 2
  [[ -e "$f" || -L "$f" ]] || return 0
  if [[ -L "$f" ]] || ! grep -qF "$OMW_MANAGED_MARKER" "$f" 2>/dev/null; then
    omw_warn "$f is not managed by omarchy-wsl; leaving it in place."
    return 0
  fi
  rm -f -- "$f"
}

# -----------------------------------------------------------------------------
# 5. systemd lingering (offline marker first; loginctl only under systemd)
# -----------------------------------------------------------------------------
linger_enabled() { [[ -e "$OMW_LINGER_DIR/$1" ]]; }

configure_linger() {
  local name="$1" f
  validate_username "$name" || return 2
  _omw_ensure_dir 0755 "$OMW_LINGER_DIR" || return 1
  f="$OMW_LINGER_DIR/$name"
  if [[ ! -e "$f" ]]; then
    : >"$f" || return 1
  fi
  chmod 0644 "$f" 2>/dev/null || true
  _omw_chown root:root "$f" || return 1
  if omw_systemd_running && omw_have loginctl; then
    if ! _omw_bounded 15 loginctl enable-linger "$name" 9>&-; then
      omw_warn "loginctl enable-linger $name failed; the on-disk marker takes effect at the next boot."
    fi
  fi
  return 0
}

remove_linger() {
  local name="$1"
  validate_username "$name" || return 2
  if omw_systemd_running && omw_have loginctl; then
    _omw_bounded 15 loginctl disable-linger "$name" 9>&- || true
  fi
  rm -f -- "${OMW_LINGER_DIR:?}/$name"
}

# _omw_bounded <seconds> <cmd...> — run with timeout(1) when available.
_omw_bounded() {
  local secs="$1"
  shift
  if omw_have timeout; then
    timeout --kill-after=5 "$secs" "$@"
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------------
# 6. /etc/wsl.conf [user] default (atomic INI edit)
# -----------------------------------------------------------------------------
# Replaces `default` in the first [user] section (dropping duplicates), adds the
# key or the section when missing, and preserves every other byte.
_omw_wsl_conf_render() {
  awk -v new_user="$1" '
function is_section(l) { return l ~ /^[ \t]*\[[^]]*\][ \t]*([#;].*)?$/ }
function is_user(l,   t) { t = tolower(l); gsub(/[ \t]/, "", t); sub(/[#;].*$/, "", t); return t == "[user]" }
function is_default(l,   t) { t = tolower(l); return t ~ /^[ \t]*default[ \t]*=/ }
{ line = $0; sub(/\r$/, "", line) }
is_section(line) {
  if (in_user && !written) { print "default = " new_user; written = 1 }
  in_user = is_user(line)
  if (in_user) seen_user = 1
  print $0
  next
}
in_user && is_default(line) {
  if (!written) { print "default = " new_user; written = 1 }
  next
}
{ print $0 }
END {
  if (in_user && !written) { print "default = " new_user; written = 1 }
  if (!written) {
    if (NR > 0) print ""
    print "[user]"
    print "default = " new_user
  }
}' "${2:-/dev/null}"
}

# wsl_conf_default_user -> the current [user] default (empty if none).
wsl_conf_default_user() {
  [[ -r "$OMW_WSL_CONF" ]] || return 0
  awk '
{ line = $0; sub(/\r$/, "", line) }
line ~ /^[ \t]*\[/ { t = tolower(line); gsub(/[ \t]/, "", t); sub(/[#;].*$/, "", t); in_user = (t == "[user]"); next }
in_user && tolower(line) ~ /^[ \t]*default[ \t]*=/ { sub(/^[^=]*=[ \t]*/, "", line); sub(/[ \t]+$/, "", line); gsub(/"/, "", line); print line; exit }
' "$OMW_WSL_CONF"
}

update_wsl_conf_default_user() {
  local name="$1" src="/dev/null"
  validate_username "$name" || { omw_err "wsl.conf: $OMW_ACCT_REASON"; return 2; }
  [[ -d "$(dirname -- "$OMW_WSL_CONF")" ]] || mkdir -p -- "$(dirname -- "$OMW_WSL_CONF")" || return 1
  [[ -f "$OMW_WSL_CONF" ]] && src="$OMW_WSL_CONF"
  _omw_wsl_conf_render "$name" "$src" | omw_atomic_write "$OMW_WSL_CONF" 0644 root:root
}

# -----------------------------------------------------------------------------
# 7. Sentinel & /etc/omarchy-user.conf
# -----------------------------------------------------------------------------
_omw_now() {
  if [[ -n "${OMARCHY_NOW:-}" ]]; then
    printf '%s\n' "$OMARCHY_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown
  fi
}

# write_sentinel <name> [writer] — /var/lib/omarchy/oobe_completed, atomic.
write_sentinel() {
  local name="$1" writer="${2:-oobe}"
  validate_username "$name" || { omw_err "sentinel: $OMW_ACCT_REASON"; return 2; }
  _omw_ensure_dir 0755 "$OMW_SENTINEL_DIR" || return 1
  {
    printf '# Omarchy-WSL OOBE completion sentinel. Identity is keyed on PROVISIONED_UID;\n'
    printf '# PROVISIONED_USER is informational. Parsed, never sourced.\n'
    printf 'OOBE_VERSION=%s\n' "$OMW_ACCT_VERSION"
    printf 'PROVISIONED_UID=%s\n' "$OMW_OWNER_UID"
    printf 'PROVISIONED_USER=%s\n' "$name"
    printf 'WRITTEN_BY=%s\n' "$writer"
    printf 'COMPLETED_AT=%s\n' "$(_omw_now)"
  } | omw_atomic_write "$OMW_SENTINEL_FILE" 0644 root:root
}

# sentinel_get <KEY> -> value from the sentinel (whitelisted keys only).
sentinel_get() {
  case "$1" in
    OOBE_VERSION|PROVISIONED_UID|PROVISIONED_USER|WRITTEN_BY|COMPLETED_AT) ;;
    *) return 2 ;;
  esac
  omw_kv_get "$OMW_SENTINEL_FILE" "$1"
}

# True when the sentinel records a completed provisioning of uid 1000.
sentinel_provisioned() {
  local uid
  uid="$(sentinel_get PROVISIONED_UID 2>/dev/null)" || return 1
  [[ "$uid" == "$OMW_OWNER_UID" ]]
}

# write_user_conf <name> — sets DEFAULT_USER, keeps every other line. A missing
# /etc/omarchy-user.conf is seeded from the shipped template, so the documented
# keys (OMARCHY_HOME_DIRS, ...) are there for the administrator to edit.
write_user_conf() {
  local name="$1" src="$OMW_USER_CONF"
  validate_username "$name" || { omw_err "user.conf: $OMW_ACCT_REASON"; return 2; }
  [[ -d "$(dirname -- "$OMW_USER_CONF")" ]] || mkdir -p -- "$(dirname -- "$OMW_USER_CONF")" || return 1
  if [[ ! -f "$src" && -f "$OMW_USER_CONF_TEMPLATE" ]]; then
    src="$OMW_USER_CONF_TEMPLATE"
  fi
  omw_kv_render "$src" DEFAULT_USER "$name" | omw_atomic_write "$OMW_USER_CONF" 0644 root:root
}

# user_conf_default_user -> validated DEFAULT_USER preseed (empty if unset/invalid)
user_conf_default_user() {
  local v
  v="$(omw_kv_get "$OMW_USER_CONF" DEFAULT_USER 2>/dev/null)" || return 0
  [[ -n "$v" ]] || return 0
  if validate_username "$v"; then
    printf '%s\n' "$v"
  else
    omw_warn "Ignoring DEFAULT_USER in $OMW_USER_CONF: $OMW_ACCT_REASON"
  fi
}

# user_conf_home_dirs -> one validated relative directory per line from
# OMARCHY_HOME_DIRS (space separated; no absolute paths, no "..", max 32).
user_conf_home_dirs() {
  local v d n=0 re='^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$'
  v="$(omw_kv_get "$OMW_USER_CONF" OMARCHY_HOME_DIRS 2>/dev/null)" || return 0
  for d in $v; do
    if [[ ! "$d" =~ $re || "/$d/" == */../* || "/$d/" == */./* ]]; then
      omw_warn "Ignoring OMARCHY_HOME_DIRS entry '$d' (must be a relative path without '..')."
      continue
    fi
    n=$((n + 1))
    if (( n > 32 )); then
      omw_warn "OMARCHY_HOME_DIRS: only the first 32 entries are used."
      break
    fi
    printf '%s\n' "$d"
  done
}

# -----------------------------------------------------------------------------
# 8. Locking shared by the OOBE and omarchy-rename-owner
# -----------------------------------------------------------------------------
# omw_acct_lock -> 0 locked, 75 busy, 1 error
omw_acct_lock() {
  local dir
  dir="$(dirname -- "$OMW_LOCK_FILE")"
  if ! _omw_ensure_dir 0755 "$dir" 2>/dev/null; then
    # /run missing or read-only (chroot, image build): fall back to the state dir.
    _omw_ensure_dir 0755 "$OMW_SENTINEL_DIR" || return 1
    OMW_LOCK_FILE="$OMW_SENTINEL_DIR/.account.lock"
  fi
  omw_lock_acquire "$OMW_LOCK_FILE"
}
