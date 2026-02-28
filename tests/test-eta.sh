#!/usr/bin/env bash
# test-eta.sh - ETA calculation tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CU_DATA_DIR="$TEST_DIR/data"
export CU_CACHE_DIR="$TEST_DIR/cache"
export CU_NO_COLOR=1

source "${SCRIPT_DIR}/../lib/util.sh"
source "${SCRIPT_DIR}/../lib/fetch.sh"
source "${SCRIPT_DIR}/../lib/history.sh"
source "${SCRIPT_DIR}/../lib/render.sh"

CU_HISTORY_FILE="${CU_DATA_DIR}/history.jsonl"

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

assert_nonzero() {
    local desc="$1" actual="$2"
    if [ -n "$actual" ] && [ "$actual" != "0" ]; then
        printf "  PASS: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (expected non-zero, got %q)\n" "$desc" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== ETA Projection Tests ==="

# Create history with linear increase: 20% over 10 hours = 2%/hour
# At 42%, 58% remaining -> ~29 hours to 100%
export CU_NOW=1709053200 # last entry time
cp "${SCRIPT_DIR}/fixtures/history.jsonl" "$CU_HISTORY_FILE"

eta_info=$(cu_eta_projection "seven_day" 168 2>/dev/null)
assert_nonzero "eta produces output with history" "$eta_info"

if [ -n "$eta_info" ]; then
    eval "$eta_info"
    assert_nonzero "rate is non-zero" "${rate:-0}"
    assert_nonzero "eta_hours is non-zero" "${eta_hours:-0}"
    assert_nonzero "eta_secs is non-zero" "${eta_secs:-0}"
fi

echo ""
echo "=== ETA with Insufficient Data ==="

# Empty history
> "$CU_HISTORY_FILE"
eta_info=$(cu_eta_projection "seven_day" 168 2>/dev/null || true)
assert_eq "no eta with empty history" "" "$eta_info"

# Single entry
echo '{"ts":1709100000,"five_hour":{"util":10,"resets_at":""},"seven_day":{"util":30,"resets_at":""}}' > "$CU_HISTORY_FILE"
eta_info=$(cu_eta_projection "seven_day" 168 2>/dev/null || true)
assert_eq "no eta with single entry" "" "$eta_info"

echo ""
echo "=== Duration Formatting ==="

result=$(cu_fmt_duration 3661)
assert_eq "1h 1m" "1h 1m" "$result"

result=$(cu_fmt_duration 90061)
assert_eq "1d 1h" "1d 1h" "$result"

result=$(cu_fmt_duration 300)
assert_eq "5m" "5m" "$result"

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
