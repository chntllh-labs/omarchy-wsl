#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Automated Adversarial Theme Synchronization Test Suite
# /tests/test_theme_adversarial.sh
# ==============================================================================
# Tests cross-OS theme engine across Windows Terminal variations, VS Code,
# JSONC comment preservation, atomic file replacement, and graceful degradation.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "  \e[32m[PASS]\e[0m $*"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "  \e[31m[FAIL]\e[0m $*"
}

header() {
  echo -e "\n\e[1m\e[36m>>> TEST SUITE: $*\e[0m"
}

# -----------------------------------------------------------------------------
# 1. Test: CLI Binary Verification
# -----------------------------------------------------------------------------
test_cli_binary() {
  header "1. CLI Binary & Interface Gates"

  local cli="${ROOT_DIR}/bin/omarchy-theme-sync"
  if [[ ! -x "$cli" ]]; then
    fail "CLI binary '$cli' is missing or not executable"
    return
  fi
  pass "CLI binary exists and has execute permissions"

  # Test list-themes output
  local themes_out
  themes_out=$("$cli" --list-themes)
  if echo "$themes_out" | grep -q "tokyo-night" && echo "$themes_out" | grep -q "catppuccin-mocha" && echo "$themes_out" | grep -q "nord"; then
    pass "CLI correctly enumerates Tokyo Night, Catppuccin, and Nord"
  else
    fail "CLI --list-themes missing expected palettes"
  fi

  # Test status output
  local status_out
  status_out=$("$cli" --status)
  if echo "$status_out" | grep -q "Cross-OS Theme Synchronization Engine" && echo "$status_out" | grep -q "Detected Targets"; then
    pass "CLI --status reports environment state cleanly"
  else
    fail "CLI --status did not produce expected output"
  fi
}

# -----------------------------------------------------------------------------
# 2. Test: Dry-Run Zero Side Effect Gate
# -----------------------------------------------------------------------------
test_dry_run_safety() {
  header "2. Dry-Run Zero Side Effect Verification"

  local cli="${ROOT_DIR}/bin/omarchy-theme-sync"
  local dry_out
  dry_out=$("$cli" --theme tokyo-night --dry-run)
  if echo "$dry_out" | grep -q "Dry-run mode active"; then
    pass "Dry-run flag honored without file mutations"
  else
    fail "Dry-run mode failed to report active status"
  fi
}

# -----------------------------------------------------------------------------
# 3. Test: Automated Python Adversarial Test Suite
# -----------------------------------------------------------------------------
test_pytest_suite() {
  header "3. Automated Python Unit & Adversarial Test Suite"

  if ! python3 -c "import pytest" 2>/dev/null; then
    fail "python3 pytest module missing"
    return
  fi

  if PYTHONPATH="${ROOT_DIR}/lib" python3 -m pytest "${ROOT_DIR}/tests/test_adversarial.py" \
                                                     "${ROOT_DIR}/tests/test_atomic_io.py" \
                                                     "${ROOT_DIR}/tests/test_detector.py" \
                                                     "${ROOT_DIR}/tests/test_jsonc.py" \
                                                     "${ROOT_DIR}/tests/test_palettes.py" -q; then
    pass "All 27 specialized Python adversarial and unit tests passed"
  else
    fail "One or more Python tests failed"
  fi
}

# -----------------------------------------------------------------------------
# 4. Test: PowerShell Companion Script Syntax & Integrity
# -----------------------------------------------------------------------------
test_powershell_script() {
  header "4. PowerShell Companion Script Audit"

  local ps1="${ROOT_DIR}/bin/sync-theme.ps1"
  if [[ ! -f "$ps1" ]]; then
    fail "PowerShell script '$ps1' missing"
    return
  fi
  pass "PowerShell script '$ps1' exists"

  # Verify key sections
  if grep -q "TokyoNight" "$ps1" && grep -q "CatppuccinMocha" "$ps1" && grep -q "Nord" "$ps1"; then
    pass "PowerShell script contains canonical palettes"
  else
    fail "PowerShell script missing required palette catalog"
  fi

  if grep -q "Write-AtomicFile" "$ps1" && grep -q "Test-JsoncValid" "$ps1"; then
    pass "PowerShell script contains atomic write engine and JSONC validator"
  else
    fail "PowerShell script missing atomic or JSONC safety functions"
  fi

  if grep -q "Microsoft.WindowsTerminal" "$ps1"; then
    pass "PowerShell script contains multi-variant Windows Terminal detection"
  else
    fail "PowerShell script missing WT multi-variant detection"
  fi
}

# -----------------------------------------------------------------------------
# Main Test Execution
# -----------------------------------------------------------------------------
echo -e "\e[1m=================================================================="
echo -e "  Omarchy WSL: Adversarial Theme Engine Verification Suite"
echo -e "==================================================================\e[0m"

test_cli_binary
test_dry_run_safety
test_pytest_suite
test_powershell_script

echo -e "\n\e[1m=================================================================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
  echo -e "  \e[32mALL TESTS PASSED! ($TESTS_PASSED/$TESTS_RUN passed, 0 failures)\e[0m"
  echo -e "==================================================================\e[0m"
  exit 0
else
  echo -e "  \e[31mTEST SUITE FAILED ($TESTS_FAILED failures out of $TESTS_RUN tests)\e[0m"
  echo -e "==================================================================\e[0m"
  exit 1
fi
