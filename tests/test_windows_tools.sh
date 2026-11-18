#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Windows-side tools suite
# /tests/test_windows_tools.sh
# ==============================================================================
# Runs tests/test_windows_tools.ps1 under pwsh: tools/generate-wslconfig.ps1,
# tools/register-wsl-autostart.ps1, install/install.ps1, bin/sync-theme.ps1,
# the Explorer context menu files, the WSL manifest fragment and a parse of
# every *.ps1 in the repository (as UTF-8 and as Windows PowerShell 5.1 reads
# BOM-less files). Then adds checks that need no PowerShell: python3 decodes
# the .reg REG_EXPAND_SZ values and checks the manifest fragment with the
# structural rules of Microsoft's distributions/validate-modern.py.
#
#   PWSH=/path/to/pwsh bash tests/test_windows_tools.sh
#   OMW_STRICT=1 bash tests/test_windows_tools.sh    # a skipped check fails the suite
#
# Messages go through printf %s, so backslashes in check names (Windows paths,
# regex anchors) are printed as they are.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  \e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  \e[31m[FAIL]\e[0m %s\n' "$*"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  \e[33m[SKIP]\e[0m %s\n' "$*"; }
header() { echo -e "\n\e[1m\e[36m>>> TEST SUITE: $*\e[0m"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

PWSH="${PWSH:-$(command -v pwsh || true)}"
PYTHON="${PYTHON:-$(command -v python3 || true)}"

# -----------------------------------------------------------------------------
header "1. PowerShell checks (tests/test_windows_tools.ps1)"
# -----------------------------------------------------------------------------
if [[ -n "$PWSH" ]]; then
  ps_out=$("$PWSH" -NoProfile -NonInteractive -File "$SCRIPT_DIR/test_windows_tools.ps1" 2>&1)
  ps_rc=$?
  failed_before=$TESTS_FAILED
  reported=0
  while IFS= read -r line; do
    case "$line" in
      "PASS: "*) pass "${line#PASS: }"; reported=$((reported + 1)) ;;
      "FAIL: "*) fail "${line#FAIL: }"; reported=$((reported + 1)) ;;
      "SKIP: "*) skip "${line#SKIP: }"; reported=$((reported + 1)) ;;
      ">>> "*) printf '\n  \e[1m%s\e[0m\n' "${line#>>> }" ;;
      "Windows Tools (PowerShell):"* | "") ;;
      *) echo "      $line" ;;
    esac
  done <<<"$ps_out"
  if (( ps_rc != 0 && TESTS_FAILED == failed_before )); then
    fail "test_windows_tools.ps1 exited $ps_rc without reporting a failing check"
  fi
  check "test_windows_tools.ps1 reported its checks ($reported)" test "$reported" -gt 100
else
  skip "pwsh not installed: PowerShell checks not run (set PWSH=/path/to/pwsh)"
fi

# -----------------------------------------------------------------------------
header "2. Checks that need no PowerShell"
# -----------------------------------------------------------------------------
check "tools/generate-wslconfig.sh (sized from guest RAM) is gone" test ! -e "$ROOT_DIR/tools/generate-wslconfig.sh"
check "winget/ (no wsl InstallerType in winget) is gone" test ! -e "$ROOT_DIR/winget"
check "tools/register-wsl-autostart.ps1 exists" test -f "$ROOT_DIR/tools/register-wsl-autostart.ps1"
check "distributions/README.md exists" test -f "$ROOT_DIR/distributions/README.md"

if [[ -n "$PYTHON" ]]; then
  check ".reg: CRLF, three REG_EXPAND_SZ commands running the absolute wt.exe alias path (python3)" \
    "$PYTHON" -I - "$ROOT_DIR/tools/register-explorer-context-menu.reg" <<'PY'
import re, sys
raw = open(sys.argv[1], 'rb').read()
text = raw.decode('ascii')
assert text.startswith('Windows Registry Editor Version 5.00\r\n'), 'header'
assert b'\n' not in raw.replace(b'\r\n', b''), 'LF-only line ending'
joined = re.sub(r'\\\r\n\s*', '', text)
values = re.findall(r'(?m)^@=hex\(2\):([0-9a-f,]+)\r$', joined)
assert len(values) == 3, values
want = '"%LOCALAPPDATA%\\Microsoft\\WindowsApps\\wt.exe" -w 0 new-tab -p "Omarchy" -d "%V."\0'
for v in values:
    got = bytes(int(b, 16) for b in v.split(',')).decode('utf-16-le')
    assert got == want, got
assert not re.search(r'(?m)^@=".*wt\.exe', text), 'bare wt.exe REG_SZ command'
PY

  check "Manifest fragment passes validate-modern.py's structural rules (python3)" \
    "$PYTHON" -I - "$ROOT_DIR/distributions/DistributionInfo.fragment.json" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
assert list(doc) == ['ModernDistributions'], list(doc)
for flavor, versions in doc['ModernDistributions'].items():
    assert flavor == 'Omarchy', flavor
    assert sum(1 for e in versions if e.get('Default')) == 1, 'exactly one default'
    for e in versions:
        assert set(e) <= {'Name', 'FriendlyName', 'Default', 'Amd64Url', 'Arm64Url'}, set(e)
        assert e['Name'].startswith(flavor) and e['FriendlyName'], e
        for key, asset in (('Amd64Url', 'Omarchy-x86_64.wsl'), ('Arm64Url', 'Omarchy-arm64.wsl')):
            url = e[key]
            assert url['Url'] == 'https://github.com/chntllh-labs/omarchy-wsl/releases/download/v4.5.0/' + asset, url
            sha = url['Sha256']
            assert re.fullmatch(r'(0x)?[0-9a-fA-F]{64}', sha), sha
            assert len(bytes.fromhex(sha[2:] if sha.startswith('0x') else sha)) == 32
PY

  check "Windows-side scripts owned by this suite are ASCII-only (python3)" \
    "$PYTHON" -I - "$ROOT_DIR" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
files = ['tools/generate-wslconfig.ps1', 'tools/register-wsl-autostart.ps1', 'install/install.ps1',
         'bin/sync-theme.ps1', 'tools/register-explorer-context-menu.ps1', 'tests/test_windows_tools.ps1',
         'tools/register-explorer-context-menu.reg', 'tools/unregister-explorer-context-menu.reg',
         'wsl/wslconfig.example', 'distributions/DistributionInfo.fragment.json']
bad = [f for f in files if any(b > 127 for b in (root / f).read_bytes())]
assert not bad, bad
PY
else
  skip "python3 not installed: .reg decoding and manifest checks not run"
fi

echo
if [[ "${OMW_STRICT:-0}" == 1 ]] && (( TESTS_SKIPPED > 0 )); then
  echo "OMW_STRICT=1: ${TESTS_SKIPPED} skipped check(s) count as failures."
fi
echo "Windows Tools Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
[[ "${OMW_STRICT:-0}" == 1 ]] && (( TESTS_SKIPPED > 0 )) && exit 1
exit 0
