#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Theme Engine Test Suite (CLI level)
# tests/test_theme_adversarial.sh
# ==============================================================================
# Drives bin/omarchy-theme-sync end to end in a sandboxed HOME: listing,
# status, dry-run without side effects, real Linux-terminal syncs that keep
# user configuration, the installed /usr layout, and the Windows-side
# companion script (parsed with pwsh). The Python unit tests run separately
# under pytest (tests/test_*.py).
# OMW_STRICT=1 turns every skip into a failing exit status.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_OK=$'\e[32m' C_BAD=$'\e[31m' C_SKIP=$'\e[33m' C_HDR=$'\e[1;36m' C_END=$'\e[0m'
else
  C_OK="" C_BAD="" C_SKIP="" C_HDR="" C_END=""
fi
pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  %s[PASS]%s %s\n' "$C_OK" "$C_END" "$*"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  %s[FAIL]%s %s\n' "$C_BAD" "$C_END" "$*"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  %s[SKIP]%s %s\n' "$C_SKIP" "$C_END" "$*"; }
header() { printf '\n%s>>> %s%s\n' "$C_HDR" "$*" "$C_END"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

CLI="$ROOT_DIR/bin/omarchy-theme-sync"
T=$(mktemp -d "${TMPDIR:-/tmp}/omw-theme.XXXXXX")
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
PWSH="${PWSH:-$(command -v pwsh || true)}"

# Sandboxed user: no Windows host, fake terminal binaries on PATH.
SANDBOX_ENV=(HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" PATH="$T/bin:/usr/bin:/bin" NO_COLOR=1)
mkdir -p "$T/home/.config" "$T/bin"
for t in ghostty kitty alacritty; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$t"; chmod +x "$T/bin/$t"; done
run_cli() { env -u WSL_DISTRO_NAME -u WSL_INTEROP "${SANDBOX_ENV[@]}" python3 "$CLI" "$@"; }

# -----------------------------------------------------------------------------
header "1. CLI interface"
check "CLI is executable" test -x "$CLI"
out=$(run_cli --list-themes)
check "--list-themes enumerates Tokyo Night, Catppuccin and Nord" \
  bash -c "grep -q tokyo-night <<<\"\$1\" && grep -q catppuccin-mocha <<<\"\$1\" && grep -q nord <<<\"\$1\"" _ "$out"
out=$(run_cli --status)
check "--status reports detected targets" grep -q 'Detected Targets' <<<"$out"
run_cli --theme no-such-theme >/dev/null 2>&1; rc=$?
check "Unknown theme exits 1" test "$rc" -eq 1

# -----------------------------------------------------------------------------
header "2. Dry run has no side effects"
before=$(find "$T/home" | sort)
out=$(run_cli --theme tokyo-night --dry-run --target linux); rc=$?
check "--dry-run exits 0 and says so" bash -c "[[ $rc -eq 0 ]] && grep -q 'Dry-run mode active' <<<\"\$1\"" _ "$out"
check "--dry-run creates no file or directory" test "$(find "$T/home" | sort)" = "$before"

# -----------------------------------------------------------------------------
header "3. Linux terminals: user configuration is kept"
mkdir -p "$T/home/.config/alacritty" "$T/home/.config/ghostty"
printf '[[keyboard.bindings]]\nkey = "N"\nmods = "Control"\naction = "CreateNewWindow"\n\n[colors.primary]\nbackground = "#000000"\n' \
  >"$T/home/.config/alacritty/alacritty.toml"
printf 'font-size = 13\n' >"$T/home/.config/ghostty/config"
run_cli --theme nord --target linux >/dev/null; rc1=$?
run_cli --theme tokyo-night --target linux >/dev/null; rc2=$?
check "Two syncs succeed" bash -c "[[ $rc1 -eq 0 && $rc2 -eq 0 ]]"
al="$T/home/.config/alacritty/alacritty.toml"
check "Alacritty: [[keyboard.bindings]] kept, [colors.primary] not duplicated" \
  bash -c "[[ \$(grep -c '^\\[\\[keyboard.bindings\\]\\]' '$al') -eq 1 && \$(grep -c '^\\[colors.primary\\]' '$al') -eq 1 ]]"
check "Alacritty: theme lives in omarchy-theme.toml, imported once" \
  bash -c "[[ -f '$T/home/.config/alacritty/omarchy-theme.toml' && \$(grep -c 'omarchy-theme.toml' '$al') -eq 1 ]]"
check "Alacritty config is still valid TOML" python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$al"
check "Ghostty: one managed block, user line kept" \
  bash -c "[[ \$(grep -c 'omarchy-theme-sync (managed block' '$T/home/.config/ghostty/config') -eq 1 ]] && grep -qx 'font-size = 13' '$T/home/.config/ghostty/config'"
check "Kitty: theme file + single include" \
  bash -c "[[ -f '$T/home/.config/kitty/current-theme.conf' && \$(grep -c 'include current-theme.conf' '$T/home/.config/kitty/kitty.conf') -eq 1 ]]"
check "No lock or staging files left behind" bash -c "! find '$T/home' -name '*.omarchy-lock' -o -name '*.omarchy_tmp.*' | grep -q ."

# -----------------------------------------------------------------------------
header "4. Installed layout (/usr/bin + /usr/lib/omarchy-wsl/python)"
mkdir -p "$T/usr/bin" "$T/usr/lib/omarchy-wsl/python"
cp "$CLI" "$T/usr/bin/omarchy-theme-sync"
cp -R "$ROOT_DIR/lib/omarchy_theme" "$T/usr/lib/omarchy-wsl/python/"
out=$(cd "$T" && env -u PYTHONPATH -u OMARCHY_THEME_LIB python3 "$T/usr/bin/omarchy-theme-sync" --list-themes 2>&1); rc=$?
check "Installed CLI finds the library under lib/omarchy-wsl/python" bash -c "[[ $rc -eq 0 ]] && grep -q nord <<<\"\$1\"" _ "$out"

# -----------------------------------------------------------------------------
header "5. Windows-side companion (bin/sync-theme.ps1)"
ps1="$ROOT_DIR/bin/sync-theme.ps1"
check "sync-theme.ps1 has the palette catalog, atomic writer and JSONC validator" \
  bash -c "grep -q TokyoNight '$ps1' && grep -q Write-AtomicFile '$ps1' && grep -q Test-JsoncValid '$ps1'"
if [[ -n "$PWSH" ]]; then
  cat >"$T/parse.ps1" <<'PS'
param([string]$Path)
$errs = $null; $tok = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 }
PS
  check "sync-theme.ps1 parses (pwsh)" "$PWSH" -NoProfile -NonInteractive -File "$T/parse.ps1" -Path "$ps1"
else
  skip "pwsh not installed: sync-theme.ps1 not parsed"
fi

echo
echo "Theme Adversarial Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-0}" == 1 ]]; then exit 1; fi
exit 0
