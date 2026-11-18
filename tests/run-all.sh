#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: run every test suite (strict by default)
# ==============================================================================
#   tests/run-all.sh [--lint-only] [--no-lint] [--no-upstream]
#
# 1. lint    shellcheck -x on every shell script, PowerShell AST parse of every
#            *.ps1 (pwsh)
# 2. python  pytest over tests/ (pyproject.toml: pythonpath=lib)
# 3. shell   every tests/test_*.sh suite
#
# OMW_STRICT=1 (the default here) turns every skip into a failure, in pytest
# (tests/conftest.py) and in the bash suites, so a missing tool can never pass
# silently. Upstream-parity tests need OMARCHY_SRC, a checkout of the pinned
# upstream commit; unless --no-upstream is given or OMARCHY_SRC is set, the
# runner fetches exactly that commit (depth 1) into a cache directory.
# Exit status is non-zero if any suite failed (or skipped, when strict).
# ==============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1
export OMW_STRICT="${OMW_STRICT:-1}"

LINT=1 TESTS=1 UPSTREAM=1
for arg in "$@"; do
  case "$arg" in
    --lint-only) TESTS=0 ;;
    --no-lint) LINT=0 ;;
    --no-upstream) UPSTREAM=0 ;;
    -h | --help)
      sed -n '5,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "run-all: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done

RESULTS=()
OVERALL=0
record() { # record <suite> <passed> <failed> <skipped> <rc>
  local suite="$1" p="$2" f="$3" s="$4" rc="$5" status=PASS
  if ((rc != 0 || f > 0)) || { ((s > 0)) && [[ $OMW_STRICT == 1 ]]; }; then
    status=FAIL
    OVERALL=1
  fi
  RESULTS+=("$(printf '%-38s %6s %6s %6s  %s' "$suite" "$p" "$f" "$s" "$status")")
}

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

shell_files() {
  {
    printf '%s\n' bin/omarchy-* wsl/overlay/bin/* wsl/bin/* lib/omarchy-wsl-migration-gate \
      wsl/oobe.sh wsl/pacman-init.sh wsl/lib/apply-etc-overrides
    find lib wsl scripts build tests -type f -name '*.sh' 2>/dev/null
  } | while read -r f; do
    [[ -f $f ]] || continue
    case "$(head -n 1 "$f")" in
      *python*) continue ;;
    esac
    echo "$f"
  done | LC_ALL=C sort -u
}

if ((LINT)); then
  section "lint: shellcheck"
  if command -v shellcheck >/dev/null; then
    mapfile -t files < <(shell_files)
    if shellcheck -x "${files[@]}"; then
      record "shellcheck (${#files[@]} files)" "${#files[@]}" 0 0 0
    else
      record "shellcheck (${#files[@]} files)" 0 1 0 1
    fi
  else
    echo "shellcheck not installed"
    record "shellcheck" 0 0 1 0
  fi

  section "lint: PowerShell parse"
  mapfile -t ps1 < <(git ls-files '*.ps1' 2>/dev/null || find . -name '*.ps1' -not -path './.git/*' | sed 's|^\./||')
  if command -v pwsh >/dev/null; then
    # shellcheck disable=SC2016 # PowerShell variables, expanded by pwsh
    if pwsh -NoLogo -NoProfile -Command '
      $bad = 0
      foreach ($f in $args) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { $bad++; $errors | ForEach-Object { Write-Host ("{0}:{1}: {2}" -f $f, $_.Extent.StartLineNumber, $_.Message) } }
        else { Write-Host "ok  $f" }
      }
      exit $bad' "${ps1[@]}"; then
      record "pwsh parse (${#ps1[@]} scripts)" "${#ps1[@]}" 0 0 0
    else
      record "pwsh parse (${#ps1[@]} scripts)" 0 1 0 1
    fi
  else
    echo "pwsh not installed"
    record "pwsh parse" 0 0 1 0
  fi
fi

if ((TESTS)); then
  if ((UPSTREAM)) && [[ -z ${OMARCHY_SRC:-} ]]; then
    commit=$(sed -n 's/^OMARCHY_COMMIT=//p' upstream.lock)
    url=$(sed -n 's/^OMARCHY_SOURCE_URL=//p' upstream.lock)
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-wsl/upstream-$commit"
    if [[ ! -d $cache/.git ]] || [[ $(git -C "$cache" rev-parse HEAD 2>/dev/null) != "$commit" ]]; then
      section "fetching upstream Omarchy ${commit:0:12} for parity tests"
      rm -rf "$cache"
      mkdir -p "$cache"
      if ! { git -C "$cache" init -q &&
        git -C "$cache" fetch -q --depth 1 "$url" "$commit" &&
        git -C "$cache" -c advice.detachedHead=false checkout -q FETCH_HEAD; }; then
        echo "could not fetch upstream; parity tests will skip"
        rm -rf "$cache"
      fi
    fi
    [[ -d $cache/.git ]] && export OMARCHY_SRC="$cache"
  fi

  section "python: pytest"
  if python3 -c 'import pytest' 2>/dev/null; then
    out=$(python3 -m pytest -q -rs -p no:cacheprovider 2>&1)
    rc=$?
    printf '%s\n' "$out" | tail -n 25
    summary=$(printf '%s\n' "$out" | grep -E '^(=+ )?[0-9]+ (passed|failed)' | tail -n 1)
    p=$(grep -oE '[0-9]+ passed' <<<"$summary" | grep -oE '[0-9]+' || echo 0)
    f=$(grep -oE '[0-9]+ (failed|errors?)' <<<"$summary" | awk '{n += $1} END {print n + 0}')
    s=$(grep -oE '[0-9]+ skipped' <<<"$summary" | grep -oE '[0-9]+' || echo 0)
    record "pytest" "${p:-0}" "${f:-0}" "${s:-0}" "$rc"
  else
    echo "pytest not installed"
    record "pytest" 0 1 0 1
  fi

  for suite in tests/test_*.sh; do
    [[ -f $suite ]] || continue
    section "shell: $suite"
    out=$(bash "$suite" 2>&1)
    rc=$?
    printf '%s\n' "$out" | tail -n 15
    line=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '[0-9]+/[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped' | tail -n 1)
    if [[ -z $line ]]; then
      echo "run-all: $suite printed no summary line" >&2
      record "$(basename "$suite")" 0 1 0 1
      continue
    fi
    p=$(sed -E 's/.* ([0-9]+)\/[0-9]+ passed.*/\1/' <<<"$line")
    f=$(sed -E 's/.* ([0-9]+) failed.*/\1/' <<<"$line")
    s=$(sed -E 's/.* ([0-9]+) skipped.*/\1/' <<<"$line")
    record "$(basename "$suite")" "$p" "$f" "$s" "$rc"
  done
fi

section "summary (OMW_STRICT=$OMW_STRICT)"
printf '%-38s %6s %6s %6s  %s\n' SUITE PASSED FAILED SKIPPED RESULT
printf '%s\n' "${RESULTS[@]}"
read -r tp tf ts < <(printf '%s\n' "${RESULTS[@]}" | awk '{p += $(NF-3); f += $(NF-2); s += $(NF-1)} END {print p + 0, f + 0, s + 0}')
printf '%-38s %6s %6s %6s  %s\n' TOTAL "$tp" "$tf" "$ts" "$([[ $OVERALL == 0 ]] && echo PASS || echo FAIL)"
exit "$OVERALL"
