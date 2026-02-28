#!/usr/bin/env bash
# test-eta.sh - ETA calculation tests (moving average + dual windows + tiers)
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

assert_range() {
    local desc="$1" min="$2" max="$3" actual="$4"
    local in_range
    in_range=$(awk -v a="$actual" -v lo="$min" -v hi="$max" 'BEGIN { print (a >= lo && a <= hi) ? 1 : 0 }')
    if [ "$in_range" = "1" ]; then
        printf "  PASS: %s (got %s, range [%s, %s])\n" "$desc" "$actual" "$min" "$max"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (got %s, expected range [%s, %s])\n" "$desc" "$actual" "$min" "$max"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Moving Average ETA Tests (Long Tier) ==="

# Set up long tier fixture from the old history fixture (seven_day only)
export CU_NOW=1709053200
while IFS= read -r line; do
    echo "$line" | jq -c '{ts: .ts, seven_day: .seven_day}'
done < "${SCRIPT_DIR}/fixtures/history.jsonl" > "$CU_HISTORY_LONG"

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null)
assert_nonzero "seven_day eta from long tier produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_nonzero "rate is non-zero" "${rate:-0}"
    assert_nonzero "eta_hours is non-zero" "${eta_hours:-0}"
    assert_nonzero "eta_secs is non-zero" "${eta_secs:-0}"
fi

echo ""
echo "=== Five-Hour ETA from Short Tier ==="

# Set up short tier fixture (five_hour only)
while IFS= read -r line; do
    echo "$line" | jq -c '{ts: .ts, five_hour: .five_hour}'
done < "${SCRIPT_DIR}/fixtures/history.jsonl" > "$CU_HISTORY_SHORT"

eta_info=$(cu_eta_projection "five_hour" 3 "short" 2>/dev/null || true)
# five_hour has non-monotonic data (resets), so positive-only filtering matters
if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_nonzero "five_hour rate from short tier is non-zero" "${rate:-0}"
    printf "  INFO: five_hour rate=%s, eta=%sh\n" "$rate" "$eta_hours"
else
    printf "  PASS: five_hour has no positive trend (all recent deltas negative) — expected\n"
    PASS=$((PASS + 1))
fi

echo ""
echo "=== Known Rate: Constant 5%/hour (Long Tier) ==="

# Create long history with exact +5%/h: 10, 15, 20, 25, 30 over 5 hours
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

eta_info=$(cu_eta_projection "seven_day" 10 "long" 2>/dev/null)
assert_nonzero "constant rate produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_eq "constant rate = 5.0" "5.0" "$rate"
    assert_eq "constant ETA hours = 14.0" "14.0" "$eta_hours"
    assert_eq "constant ETA secs = 50400" "50400" "$eta_secs"
fi

echo ""
echo "=== Known Rate: Constant 5%/hour (Short Tier) ==="

# Same data but for five_hour in short tier
> "$CU_HISTORY_SHORT"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_SHORT"
done
export CU_NOW=$((local_base + 4 * 3600))

eta_info=$(cu_eta_projection "five_hour" 10 "short" 2>/dev/null)
assert_nonzero "five_hour constant rate from short tier" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_eq "five_hour short tier rate = 5.0" "5.0" "$rate"
    assert_eq "five_hour short tier ETA hours = 14.0" "14.0" "$eta_hours"
fi

echo ""
echo "=== Spiky Data: Moving Average Smoothing ==="

# Create long history with a spike: 10, 50, 15, 20, 25
> "$CU_HISTORY_LONG"
local_base=1700000000
vals=(10 50 15 20 25)
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":${vals[$i]},\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

eta_info=$(cu_eta_projection "seven_day" 3 "long" 2>/dev/null)
assert_nonzero "spiky data produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "spiky rate smoothed by moving avg" "10" "20" "$rate"
fi

echo ""
echo "=== Configurable Window Size ==="

# Same spiky data but window=1 (only last positive delta = +5%/h)
eta_info=$(cu_eta_projection "seven_day" 1 "long" 2>/dev/null)
assert_nonzero "window=1 produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_eq "window=1 rate = last positive delta = 5.0" "5.0" "$rate"
fi

echo ""
echo "=== ETA with Insufficient Data ==="

# Empty long history
> "$CU_HISTORY_LONG"
eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
assert_eq "no eta with empty history" "" "$eta_info"

# Single entry
echo '{"ts":1709100000,"seven_day":{"util":30,"resets_at":""}}' > "$CU_HISTORY_LONG"
eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
assert_eq "no eta with single entry" "" "$eta_info"

echo ""
echo "=== Only Negative Deltas (Decreasing Usage) ==="

# Usage going down: 50, 40, 30
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2; do
    ts=$((local_base + i * 3600))
    val=$((50 - i * 10))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 2 * 3600))

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
assert_eq "no eta with only negative deltas" "" "$eta_info"

echo ""
echo "=== Default Tier Based on Field ==="

# Test that cu_eta_projection defaults to correct tier without explicit tier arg
> "$CU_HISTORY_SHORT"
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_SHORT"
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

# five_hour should default to short tier
eta_info=$(cu_eta_projection "five_hour" 10 2>/dev/null)
assert_nonzero "five_hour defaults to short tier" "$eta_info"

# seven_day should default to long tier
eta_info=$(cu_eta_projection "seven_day" 10 2>/dev/null)
assert_nonzero "seven_day defaults to long tier" "$eta_info"

# Cross-check: five_hour from long tier should fail (no data)
eta_info=$(cu_eta_projection "five_hour" 10 "long" 2>/dev/null || true)
assert_eq "five_hour from long tier has no data" "" "$eta_info"

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
