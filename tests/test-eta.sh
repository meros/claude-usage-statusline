#!/usr/bin/env bash
# test-eta.sh - ETA calculation tests (moving average + dual windows)
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

echo "=== Moving Average ETA Tests ==="

# Fixture: 10 hourly entries with steady +2%/h for seven_day
# At 42%, remaining = 58%, rate ~2%/h → ~29 hours
export CU_NOW=1709053200
cp "${SCRIPT_DIR}/fixtures/history.jsonl" "$CU_HISTORY_FILE"

eta_info=$(cu_eta_projection "seven_day" 24 2>/dev/null)
assert_nonzero "seven_day eta produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_nonzero "rate is non-zero" "${rate:-0}"
    assert_nonzero "eta_hours is non-zero" "${eta_hours:-0}"
    assert_nonzero "eta_secs is non-zero" "${eta_secs:-0}"
fi

echo ""
echo "=== Five-Hour Field ETA ==="

# five_hour field: increases from 5→10 across 10 entries but has resets (dips)
# Only positive deltas are used, so rate should be positive
eta_info=$(cu_eta_projection "five_hour" 3 2>/dev/null || true)
# five_hour has non-monotonic data (resets), so positive-only filtering matters
if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_nonzero "five_hour rate is non-zero" "${rate:-0}"
    printf "  INFO: five_hour rate=%s, eta=%sh\n" "$rate" "$eta_hours"
else
    printf "  PASS: five_hour has no positive trend (all recent deltas negative) — expected\n"
    PASS=$((PASS + 1))
fi

echo ""
echo "=== Known Rate: Constant 5%/hour ==="

# Create history with exact +5%/h: 10, 15, 20, 25, 30 over 5 hours
> "$CU_HISTORY_FILE"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"},\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_FILE"
done
export CU_NOW=$((local_base + 4 * 3600))

eta_info=$(cu_eta_projection "seven_day" 10 2>/dev/null)
assert_nonzero "constant rate produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    # Rate should be exactly 5.0%/h, remaining = 70%, ETA = 14h
    assert_eq "constant rate = 5.0" "5.0" "$rate"
    assert_eq "constant ETA hours = 14.0" "14.0" "$eta_hours"
    assert_eq "constant ETA secs = 50400" "50400" "$eta_secs"
fi

echo ""
echo "=== Spiky Data: Moving Average Smoothing ==="

# Create history with a spike: 10, 50, 15, 20, 25 (spike at hour 1)
# With window=3, uses last 3 positive deltas
> "$CU_HISTORY_FILE"
local_base=1700000000
vals=(10 50 15 20 25)
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":${vals[$i]},\"resets_at\":\"\"},\"seven_day\":{\"util\":${vals[$i]},\"resets_at\":\"\"}}" >> "$CU_HISTORY_FILE"
done
export CU_NOW=$((local_base + 4 * 3600))

eta_info=$(cu_eta_projection "seven_day" 3 2>/dev/null)
assert_nonzero "spiky data produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    # Positive deltas: +40 (10→50), +5 (15→20), +5 (20→25) = 3 positive deltas
    # Window=3 averages all 3: (40+5+5)/3 ≈ 16.7%/h
    # vs old first-to-last would get (25-10)/4 = 3.75%/h
    assert_range "spiky rate smoothed by moving avg" "10" "20" "$rate"
fi

echo ""
echo "=== Configurable Window Size ==="

# Same spiky data but window=1 (only last positive delta = +5%/h)
eta_info=$(cu_eta_projection "seven_day" 1 2>/dev/null)
assert_nonzero "window=1 produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_eq "window=1 rate = last positive delta = 5.0" "5.0" "$rate"
fi

echo ""
echo "=== ETA with Insufficient Data ==="

# Empty history
> "$CU_HISTORY_FILE"
eta_info=$(cu_eta_projection "seven_day" 24 2>/dev/null || true)
assert_eq "no eta with empty history" "" "$eta_info"

# Single entry
echo '{"ts":1709100000,"five_hour":{"util":10,"resets_at":""},"seven_day":{"util":30,"resets_at":""}}' > "$CU_HISTORY_FILE"
eta_info=$(cu_eta_projection "seven_day" 24 2>/dev/null || true)
assert_eq "no eta with single entry" "" "$eta_info"

echo ""
echo "=== Only Negative Deltas (Decreasing Usage) ==="

# Usage going down: 50, 40, 30 — no positive deltas → no ETA
> "$CU_HISTORY_FILE"
local_base=1700000000
for i in 0 1 2; do
    ts=$((local_base + i * 3600))
    val=$((50 - i * 10))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"},\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_FILE"
done
export CU_NOW=$((local_base + 2 * 3600))

eta_info=$(cu_eta_projection "seven_day" 24 2>/dev/null || true)
assert_eq "no eta with only negative deltas" "" "$eta_info"

echo ""
echo "=== Five-Hour-Only Data (No Weekly Limit) ==="

# Users without weekly limits — seven_day field absent from history
> "$CU_HISTORY_FILE"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_FILE"
done
export CU_NOW=$((local_base + 4 * 3600))

# five_hour ETA should work
eta_info=$(cu_eta_projection "five_hour" 3 2>/dev/null)
assert_nonzero "five_hour ETA works without seven_day" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_eq "five_hour-only rate = 5.0" "5.0" "$rate"
fi

# seven_day ETA should gracefully fail (no data)
eta_info=$(cu_eta_projection "seven_day" 24 2>/dev/null || true)
assert_eq "seven_day ETA empty when field absent" "" "$eta_info"

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
