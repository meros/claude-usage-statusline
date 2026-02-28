#!/usr/bin/env bash
# test-render.sh - Sparkline + bar rendering tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/util.sh"
source "${SCRIPT_DIR}/../lib/render.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf "  PASS: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n    expected: %q\n    actual:   %q\n" "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "  PASS: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (expected to contain %q)\n    actual: %q\n" "$desc" "$needle" "$haystack"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Sparkline Tests ==="

# Test sparkline with known values
CU_NO_COLOR=1
result=$(CU_OPT_WIDTH=8 cu_sparkline 0 25 50 75 100 75 50 25)
assert_eq "sparkline 8 values" "▁▂▄▆█▆▄▂" "$result"

result=$(CU_OPT_WIDTH=4 cu_sparkline 0 0 0 0)
assert_eq "sparkline all zeros" "▁▁▁▁" "$result"

result=$(CU_OPT_WIDTH=4 cu_sparkline 100 100 100 100)
assert_eq "sparkline all 100" "████" "$result"

result=$(CU_OPT_WIDTH=1 cu_sparkline 50)
assert_eq "sparkline single 50" "▄" "$result"

echo ""
echo "=== Progress Bar Tests ==="

# Progress bar (no-color mode for predictable output)
result=$(cu_progress_bar 0 10)
assert_eq "bar 0%" "░░░░░░░░░░" "$result"

result=$(cu_progress_bar 100 10)
assert_eq "bar 100%" "██████████" "$result"

result=$(cu_progress_bar 50 10)
assert_eq "bar 50%" "█████░░░░░" "$result"

echo ""
echo "=== Percentage Color Tests ==="

color=$(cu_pct_color 20)
assert_eq "20% -> green" "$CU_GREEN" "$color"

color=$(cu_pct_color 60)
assert_eq "60% -> yellow" "$CU_YELLOW" "$color"

color=$(cu_pct_color 90)
assert_eq "90% -> red" "$CU_RED" "$color"

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
