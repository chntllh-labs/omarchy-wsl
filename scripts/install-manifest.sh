#!/usr/bin/env bash
# ==============================================================================
# install-manifest: install, list or verify the files rootfs.manifest describes
# Repository: scripts/install-manifest.sh   Image: /usr/lib/omarchy-wsl/install-manifest
# ==============================================================================
#   install-manifest install --scope pkg|rootfs --destdir DIR [--srcdir DIR]
#   install-manifest list    [--scope pkg|rootfs] [--srcdir DIR]
#   install-manifest verify  [--root DIR]          (alias: --verify DIR)
#
# install writes every manifest entry of the scope into DESTDIR (rootfs scope =
# pkg entries + machine-level entries) and records each installed file as
# "<sha256> <mode> <path>" ("config <mode> <path>" for admin-editable files,
# "link <target> <path>" for symlinks) in usr/share/omarchy-wsl/manifest-<scope>.sha256.
# verify re-checks those records against a root filesystem, so the shipped
# image can prove it still matches the build (omarchy-doctor, CI smoke test).
#
# Portable to bash 3.2 and BSD userland so tests also run on macOS.
# Environment read by the generators: OMARCHY_WSL_PKGVER, OMARCHY_WSL_GIT_SHA,
# SOURCE_DATE_EPOCH (all optional; recorded in /etc/omarchy-wsl-release).
# ==============================================================================

set -euo pipefail

PROG=install-manifest
die() {
  echo "$PROG: $*" >&2
  exit 1
}
usage() {
  sed -n '6,8p' "$0" | sed 's/^#   //'
}

RECORD_DIR=usr/share/omarchy-wsl

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mode_of() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

# Normalise "0644" / "644" to "644".
norm_mode() {
  local m="$1"
  while [[ ${#m} -gt 3 && ${m:0:1} == 0 ]]; do m="${m:1}"; done
  echo "$m"
}

lock_value() {
  local key="$1" file="$SRCDIR/upstream.lock"
  [[ -r $file ]] || die "missing $file"
  awk -F= -v k="$key" '$0 ~ /^[A-Z0-9_]+=[^[:space:]]*$/ && $1 == k { print substr($0, length(k) + 2); found = 1 } END { exit found ? 0 : 1 }' "$file" ||
    die "upstream.lock has no $key"
}

# Generators -------------------------------------------------------------------
gen_os_release() {
  local version
  version=$(lock_value OMARCHY_VERSION)
  sed "s|@OMARCHY_VERSION@|${version}|g" "$SRCDIR/wsl/etc-overrides/os-release.in"
}

gen_omarchy_wsl_release() {
  printf 'OMARCHY_WSL_VERSION=%s\n' "${OMARCHY_WSL_PKGVER:-$(lock_value OMARCHY_VERSION)}"
  printf 'OMARCHY_WSL_GIT_SHA=%s\n' "${OMARCHY_WSL_GIT_SHA:-unknown}"
  printf 'OMARCHY_WSL_SOURCE_DATE_EPOCH=%s\n' "${SOURCE_DATE_EPOCH:-0}"
  printf 'OMARCHY_TAG=%s\n' "$(lock_value OMARCHY_TAG)"
  printf 'OMARCHY_VERSION=%s\n' "$(lock_value OMARCHY_VERSION)"
  printf 'OMARCHY_COMMIT=%s\n' "$(lock_value OMARCHY_COMMIT)"
  printf 'OMARCHY_CHANNEL=%s\n' "$(lock_value OMARCHY_CHANNEL)"
  printf 'OMARCHY_WSL_URL=https://github.com/chntllh-labs/omarchy-wsl\n'
}

run_generator() {
  case "$1" in
    os-release) gen_os_release ;;
    omarchy-wsl-release) gen_omarchy_wsl_release ;;
    *) die "unknown generator '$1'" ;;
  esac
}

# Manifest expansion ------------------------------------------------------------
# Prints one resolved entry per line: scope kind mode source dest
expand_manifest() {
  local want="$1" scope kind mode src dest line n f rel
  local manifest="$SRCDIR/rootfs.manifest"
  [[ -r $manifest ]] || die "missing $manifest"
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    [[ -n ${line//[[:space:]]/} ]] || continue
    # Split on whitespace without expanding the glob in the source column.
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    scope="$1"
    [[ $scope == exclude ]] && continue
    [[ $# -eq 5 ]] || die "malformed manifest line: $line"
    kind="$2" mode="$3" src="$4" dest="$5"
    case "$scope" in pkg | rootfs) ;; *) die "bad scope '$scope' in: $line" ;; esac
    [[ $dest == /* ]] || die "destination must be absolute: $line"
    if [[ $want == pkg && $scope != pkg ]]; then continue; fi
    case "$kind" in
      file | config)
        n=0
        for f in $src; do
          [[ -f $SRCDIR/$f || -f $f ]] || continue
          n=$((n + 1))
          if [[ $dest == */ ]]; then
            echo "$scope $kind $mode $f ${dest}${f##*/}"
          else
            echo "$scope $kind $mode $f $dest"
          fi
        done
        [[ $n -gt 0 ]] || die "manifest glob matches nothing: $src"
        [[ $dest == */ || $n -eq 1 ]] || die "glob '$src' must match exactly one file for $dest"
        ;;
      tree)
        [[ -d $src ]] || die "manifest tree missing: $src"
        while IFS= read -r f; do
          rel="${f#"$src"/}"
          echo "$scope file $mode $f $dest/$rel"
        done < <(find "$src" -type f ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '.DS_Store' | LC_ALL=C sort)
        ;;
      link) echo "$scope link - $src $dest" ;;
      gen) echo "$scope gen $mode $src $dest" ;;
      *) die "bad kind '$kind' in: $line" ;;
    esac
  done <"$manifest"
}

# Commands ----------------------------------------------------------------------
cmd_list() {
  (cd "$SRCDIR" && expand_manifest "$SCOPE")
}

cmd_install() {
  [[ -n $DESTDIR ]] || die "--destdir is required"
  [[ $DESTDIR == /* ]] || die "--destdir must be absolute"
  DESTDIR="${DESTDIR%/}"
  local entries scope kind mode src dest target rec
  entries=$(cd "$SRCDIR" && expand_manifest "$SCOPE")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/install-manifest.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  : >"$tmp/pkg.rec"
  : >"$tmp/rootfs.rec"
  while read -r scope kind mode src dest; do
    [[ -n $scope ]] || continue
    target="${DESTDIR}${dest}"
    mkdir -p "$(dirname "$target")"
    rm -f "$target"
    case "$kind" in
      file | config) install -m "$mode" "$SRCDIR/$src" "$target" ;;
      gen)
        run_generator "$src" >"$tmp/gen"
        install -m "$mode" "$tmp/gen" "$target"
        ;;
      link) ln -s "$src" "$target" ;;
    esac
    rec="$tmp/$scope.rec"
    if [[ $kind == link ]]; then
      printf 'link %s %s\n' "$src" "$dest" >>"$rec"
    elif [[ $kind == config ]]; then
      printf 'config %s %s\n' "$(norm_mode "$mode")" "$dest" >>"$rec"
    else
      printf '%s %s %s\n' "$(sha256_of "$target")" "$(norm_mode "$mode")" "$dest" >>"$rec"
    fi
  done <<<"$entries"
  mkdir -p "$DESTDIR/$RECORD_DIR"
  LC_ALL=C sort -k3 "$tmp/pkg.rec" >"$DESTDIR/$RECORD_DIR/manifest-pkg.sha256"
  chmod 0644 "$DESTDIR/$RECORD_DIR/manifest-pkg.sha256"
  if [[ $SCOPE == rootfs ]]; then
    LC_ALL=C sort -k3 "$tmp/rootfs.rec" >"$DESTDIR/$RECORD_DIR/manifest-rootfs.sha256"
    chmod 0644 "$DESTDIR/$RECORD_DIR/manifest-rootfs.sha256"
  fi
  echo "$PROG: installed $(wc -l <<<"$entries" | tr -d ' ') entries (scope $SCOPE) into $DESTDIR"
}

cmd_verify() {
  local root="${ROOT%/}" rec sum mode path f bad=0 checked=0 actual
  for rec in "$root/$RECORD_DIR/manifest-pkg.sha256" "$root/$RECORD_DIR/manifest-rootfs.sha256"; do
    [[ -f $rec ]] || continue
    while read -r sum mode path; do
      [[ -n $sum ]] || continue
      checked=$((checked + 1))
      f="${root}${path}"
      if [[ $sum == link ]]; then
        if [[ ! -L $f || $(readlink "$f") != "$mode" ]]; then
          echo "MISMATCH link $path (expected -> $mode)" >&2
          bad=$((bad + 1))
        fi
        continue
      fi
      if [[ ! -f $f ]]; then
        echo "MISSING $path" >&2
        bad=$((bad + 1))
        continue
      fi
      actual=$(norm_mode "$(mode_of "$f")")
      if [[ $sum == config ]]; then
        # Admin-editable configuration: presence and mode only.
        if [[ $actual != "$mode" ]]; then
          echo "MODE $path: $actual (expected $mode)" >&2
          bad=$((bad + 1))
        fi
        continue
      fi
      if [[ $actual != "$mode" ]]; then
        echo "MODE $path: $actual (expected $mode)" >&2
        bad=$((bad + 1))
      fi
      if [[ $(sha256_of "$f") != "$sum" ]]; then
        echo "CONTENT $path differs from the build" >&2
        bad=$((bad + 1))
      fi
    done <"$rec"
  done
  [[ $checked -gt 0 ]] || die "no manifest records under $root/$RECORD_DIR"
  if [[ $bad -gt 0 ]]; then
    echo "$PROG: $bad problem(s) in $checked manifest entries" >&2
    return 1
  fi
  echo "$PROG: all $checked manifest entries verified under ${root:-/}"
}

# Arguments -----------------------------------------------------------------------
CMD="${1:-}"
[[ -n $CMD ]] || {
  usage >&2
  exit 2
}
shift
SCOPE=rootfs DESTDIR="" ROOT=/
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$CMD" in
  --verify)
    CMD=verify
    ROOT="${1:-/}"
    [[ $# -gt 0 ]] && shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="${2:?--scope needs pkg or rootfs}"
      shift 2
      ;;
    --destdir)
      DESTDIR="${2:?--destdir needs a directory}"
      shift 2
      ;;
    --srcdir)
      SRCDIR="$(cd "${2:?--srcdir needs a directory}" && pwd)"
      shift 2
      ;;
    --root)
      ROOT="${2:?--root needs a directory}"
      shift 2
      ;;
    *)
      echo "$PROG: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done
case "$SCOPE" in pkg | rootfs) ;; *) die "--scope must be pkg or rootfs" ;; esac

case "$CMD" in
  install) cmd_install ;;
  list) cmd_list ;;
  verify) cmd_verify ;;
  *)
    echo "$PROG: unknown command: $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
