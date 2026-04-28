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
    # Sum of positive deltas: 5+5+5+5 = 20. Wall-clock window = 10h.
    # rate = 20/10 = 2.0 %/h. remaining = 100-30 = 70. hours = 70/2 = 35h.
    assert_range "constant rate = 2.0%/h (sum-of-positives over 10h window)" "1.99" "2.01" "$rate"
    assert_range "constant ETA hours = 35.0" "34.9" "35.1" "$eta_hours"
    assert_range "constant ETA secs = 126000" "125900" "126100" "$eta_secs"
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
    assert_range "five_hour short tier rate = 2.0%/h" "1.99" "2.01" "$rate"
    assert_range "five_hour short tier ETA hours = 35h" "34.9" "35.1" "$eta_hours"
fi

echo ""
echo "=== Spiky Data: Wall-Clock Rate ==="

# Create long history with a spike: 10, 50, 15, 20, 25
> "$CU_HISTORY_LONG"
local_base=1700000000
vals=(10 50 15 20 25)
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":${vals[$i]},\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

# Window=3h: anchor at hour 1 (val=50). Positive deltas i=2,3,4: -35(skip),
# +5,+5 = 10. Wall-clock = 3h. rate = 10/3 = 3.33%/h
eta_info=$(cu_eta_projection "seven_day" 3 "long" 2>/dev/null || true)
assert_nonzero "spiky 3h window with reset" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "spiky 3h: post-reset positive deltas only" "3.2" "3.4" "$rate"
fi

# Window=4h: anchor at hour 0 (val=10). Positive deltas i=1..4: +40, -35(skip),
# +5, +5 = 50. Wall-clock = 4h. rate = 50/4 = 12.5%/h
eta_info=$(cu_eta_projection "seven_day" 4 "long" 2>/dev/null)
assert_nonzero "spiky 4h window counts both sides" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "spiky 4h: positive-deltas-only consumption" "12.4" "12.6" "$rate"
fi

# Window=10h: no anchor (data starts at base, t_start=base-6h). Same positive
# deltas (+40,+5,+5 = 50) but wall-clock = 10h, so rate = 5.0%/h
eta_info=$(cu_eta_projection "seven_day" 10 "long" 2>/dev/null)
assert_nonzero "spiky large window counts both sides" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "spiky 10h: 50% consumption / 10h window" "4.9" "5.1" "$rate"
fi

echo ""
echo "=== Noisy Data: Sum of Positive Deltas ==="

# Each downward bounce is treated as a reset boundary, so positive deltas sum.
# Values: 10, 12, 11, 14, 13, 16, 15, 18 over 7 hours.
# Positive deltas: +2, -1(skip), +3, -1(skip), +3, -1(skip), +3 = 11.
# Window=10h → rate = 11/10 = 1.1 %/h
> "$CU_HISTORY_LONG"
local_base=1700000000
noisy_vals=(10 12 11 14 13 16 15 18)
for i in "${!noisy_vals[@]}"; do
    ts=$((local_base + i * 3600))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":${noisy_vals[$i]},\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 7 * 3600))

eta_info=$(cu_eta_projection "seven_day" 10 "long" 2>/dev/null)
assert_nonzero "noisy data produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "noisy data: sum of positive deltas / wall-clock window" "1.0" "1.2" "$rate"
fi

echo ""
echo "=== Configurable Window Size ==="

# Restore spiky data for this test: 10, 50, 15, 20, 25
> "$CU_HISTORY_LONG"
local_base=1700000000
vals=(10 50 15 20 25)
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":${vals[$i]},\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

# Window=1h: anchor at hour 3 (val=20). Last delta: +5. rate = 5/1 = 5.0%/h
eta_info=$(cu_eta_projection "seven_day" 1 "long" 2>/dev/null)
assert_nonzero "window=1 produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "window=1 rate = 5.0" "4.9" "5.1" "$rate"
fi

echo ""
echo "=== Zero Rate When No Real Data ==="

# Empty long history → rate=0, no projection
> "$CU_HISTORY_LONG"
eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
assert_eq "empty history → rate=0" "0" "${rate%.*}"
assert_eq "empty history → secs=0" "0" "${eta_secs:-}"

# Single entry → no deltas to sum → rate=0
echo '{"ts":1709100000,"seven_day":{"util":30,"resets_at":""}}' > "$CU_HISTORY_LONG"
eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
assert_eq "single entry → rate=0" "0" "${rate%.*}"

echo ""
echo "=== Only Negative Deltas (Decreasing Usage) ==="

# Usage going down: 50, 40, 30. Every delta is negative — treated as resets.
# No positive deltas → rate=0.
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2; do
    ts=$((local_base + i * 3600))
    val=$((50 - i * 10))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 2 * 3600))

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
assert_eq "only-negative-deltas → rate=0" "0" "${rate%.*}"
assert_eq "only-negative-deltas → secs=0" "0" "${eta_secs:-}"

echo ""
echo "=== Gap Handling: Weekend Gap (Real-World Scenario) ==="

# Simulate: active Fri (12%), offline Sat-Sun, back Mon (still 12% → 16%)
# Window=24h should use last known value before gap (12%), not interpolate
> "$CU_HISTORY_LONG"
local_base=1700000000
# Friday active: hourly readings 8%→12% over 4 hours
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((8 + i))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
# 46-hour gap (weekend)
# Monday: back online, usage climbed to 15% then 16% over 2 hours
for i in 0 1 2 3; do
    ts=$((local_base + 4 * 3600 + 46 * 3600 + i * 1800))  # 30-min intervals
    val=$((14 + (i > 0 ? 1 : 0) + (i > 2 ? 1 : 0)))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600 + 46 * 3600 + 3 * 1800))

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null)
assert_nonzero "weekend gap produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    # Last value before 24h-ago boundary is 12% (Fri hour 4).
    # Current value is 16%. Net = 4% over 24h = 0.17%/h
    assert_range "weekend gap: rate uses last-known value before gap" "0.1" "0.2" "$rate"
fi

echo ""
echo "=== Gap Handling: Both Sides of Reset Within Window ==="

# Heavy day: 80%→100% (pre-reset +20%), reset to 0%, then 0%→16% (post +16%)
# Total consumption = 36% over 24h = 1.5%/h
> "$CU_HISTORY_LONG"
local_base=1700000000
# Pre-reset: 80→90→100 over 4 hours
for i in 0 1 2; do
    ts=$((local_base + i * 7200))  # 2h intervals
    val=$((80 + i * 10))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
# Reset at hour 6 (2h after hitting 100%)
echo "{\"ts\":$((local_base + 6 * 3600)),\"seven_day\":{\"util\":0,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
# Post-reset: 0→8→16 over remaining 18 hours
for i in 1 2; do
    ts=$((local_base + 6 * 3600 + i * 9 * 3600))
    val=$((i * 8))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 24 * 3600))

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null)
assert_nonzero "both-sides-of-reset produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    # Positive deltas: +10, +10, -100(skip), +8, +8 = 36% over 24h = 1.5%/h
    assert_range "both sides: 20% pre + 16% post = 36%/24h" "1.49" "1.51" "$rate"
fi

echo ""
echo "=== Gap Handling: Reset Hidden in Gap ==="

# Data before gap: 80%. Gap spans a reset. After gap: 5% → 8%
> "$CU_HISTORY_LONG"
local_base=1700000000
# Before gap: 70%→80% over 2 hours
for i in 0 1 2; do
    ts=$((local_base + i * 3600))
    val=$((70 + i * 5))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
# Reset happened during 30h gap (invisible in data)
# After gap: 5%→8% over 3 hours
for i in 0 1 2 3; do
    ts=$((local_base + 2 * 3600 + 30 * 3600 + i * 3600))
    val=$((5 + i))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 2 * 3600 + 30 * 3600 + 3 * 3600))

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null)
assert_nonzero "reset-in-gap produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    # 80%→5% is a drop of 75 points — detected as reset.
    # Boundary is 24h ago: last known before that is 80% (hour 2).
    # Pre-reset: val[reset-1]=80 - start=80 = 0% (all before window).
    # Post-reset: 8-5 = 3%. Total = 3% over 24h = 0.125%/h
    assert_range "reset-in-gap: both sides counted over 24h" "0.1" "0.2" "$rate"
fi

echo ""
echo "=== Gap Handling: All Data After Window Start ==="

# Only have 2 hours of data, window is 24h
# Should clamp but require minimum coverage
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 1800))  # 30-min intervals, 2h total
    val=$((20 + i * 2))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 1800))

# 2h of data for a 24h window: positive deltas +2+2+2+2 = 8 / 24h = 0.33%/h.
# No coverage check anymore — we trust wall-clock as denominator and accept
# that sparse history simply yields a low rate.
eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null || true)
read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
assert_range "tiny data span: 8% / 24h ≈ 0.33%/h" "0.3" "0.4" "$rate"

# Same data but with window=4h: 8% / 4h = 2.0%/h
eta_info=$(cu_eta_projection "seven_day" 4 "long" 2>/dev/null)
assert_nonzero "adequate coverage produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    assert_range "small window rate = 2.0%/h" "1.99" "2.01" "$rate"
fi

echo ""
echo "=== Gap Handling: Multiple Gaps Within Window ==="

# Data: 10% at t=0, gap, 14% at t=10h, gap, 18% at t=20h, 20% at t=24h
> "$CU_HISTORY_LONG"
local_base=1700000000
echo "{\"ts\":$local_base,\"seven_day\":{\"util\":10,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
echo "{\"ts\":$((local_base + 10 * 3600)),\"seven_day\":{\"util\":14,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
echo "{\"ts\":$((local_base + 20 * 3600)),\"seven_day\":{\"util\":18,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
echo "{\"ts\":$((local_base + 24 * 3600)),\"seven_day\":{\"util\":20,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
export CU_NOW=$((local_base + 24 * 3600))

eta_info=$(cu_eta_projection "seven_day" 24 "long" 2>/dev/null)
assert_nonzero "multiple gaps produces output" "$eta_info"

if [ -n "$eta_info" ]; then
    read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
    # 10→20 over 24h = ~0.4%/h
    assert_range "multiple gaps: correct net rate" "0.3" "0.5" "$rate"
fi

echo ""
echo "=== Default Tier Based on Field ==="

# Test that cu_eta_projection defaults to correct tier without explicit tier arg
> "$CU_HISTORY_SHORT"
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"},\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_SHORT"
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

# five_hour should default to short tier
eta_info=$(cu_eta_projection "five_hour" 10 2>/dev/null)
assert_nonzero "five_hour defaults to short tier" "$eta_info"

# seven_day should also default to short tier (fine-grained data for ETA)
eta_info=$(cu_eta_projection "seven_day" 10 2>/dev/null)
assert_nonzero "seven_day defaults to short tier" "$eta_info"

# Cross-check: five_hour from long tier has no data → rate=0
eta_info=$(cu_eta_projection "five_hour" 10 "long" 2>/dev/null || true)
read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
assert_eq "five_hour from long tier → rate=0" "0" "${rate%.*}"

echo ""
echo "=== Short-to-Long Tier Fallback ==="

# When short tier has no seven_day data, should fall back to long tier
> "$CU_HISTORY_SHORT"
> "$CU_HISTORY_LONG"
local_base=1700000000
for i in 0 1 2 3 4; do
    ts=$((local_base + i * 3600))
    val=$((10 + i * 5))
    # Short tier has only five_hour (simulates pre-upgrade data)
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_SHORT"
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$val,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 4 * 3600))

# seven_day should fall back to long tier when short has no seven_day data
eta_info=$(cu_eta_projection "seven_day" 10 2>/dev/null)
assert_nonzero "seven_day falls back to long tier" "$eta_info"

echo ""
echo "=== Seasonal Template ETA (seven_day hour-of-week buckets) ==="

# Template needs ≥3 distinct days of long-tier data. Below that, returns
# nothing so the caller falls back to flat-rate ETA.
> "$CU_HISTORY_LONG"
local_base=1700000000
# 2 days of data → insufficient
for i in 0 1; do
    ts=$((local_base + i * 86400))
    echo "{\"ts\":$ts,\"seven_day\":{\"util\":$((i * 5)),\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
done
export CU_NOW=$((local_base + 1 * 86400))

tmpl=$(cu_eta_template_seven_day 5 86400 2>/dev/null || true)
assert_eq "template bails on <3 days of data" "" "$tmpl"

# Synthetic 4-week pattern: heavy use 09:00-17:00 weekdays (each hour +1%),
# zero elsewhere. Weekly reset Sunday midnight (drop counts as a reset, gets
# filtered by the negative-delta rule).
> "$CU_HISTORY_LONG"
local_base=$(date -d "2025-12-01 00:00:00" +%s 2>/dev/null || gdate -d "2025-12-01 00:00:00" +%s)
util=0
for d in $(seq 0 27); do
    for h in $(seq 0 23); do
        ts=$((local_base + d * 86400 + h * 3600))
        wd=$(date -d "@$ts" +%u 2>/dev/null || gdate -d "@$ts" +%u)
        # Weekly reset Sunday (wd=7) at midnight
        if [ "$wd" -eq 7 ] && [ "$h" -eq 0 ]; then util=0; fi
        # Increment util by 1 during business hours on weekdays
        if [ "$wd" -ge 1 ] && [ "$wd" -le 5 ] && [ "$h" -ge 9 ] && [ "$h" -lt 17 ]; then
            util=$((util + 1))
        fi
        echo "{\"ts\":$ts,\"seven_day\":{\"util\":$util,\"resets_at\":\"\"}}" >> "$CU_HISTORY_LONG"
    done
done

# Run the template at Monday 09:00 (start of a workday) with 70% util
# and 7 days until reset. Each weekday contributes 8% (8h × +1%/h), so
# 70 + 5×8 = 110% — projected to hit 100% partway through Friday.
mon_0900=$(date -d "2025-12-29 09:00:00" +%s 2>/dev/null || gdate -d "2025-12-29 09:00:00" +%s)
export CU_NOW=$mon_0900
secs_to_reset=$((7 * 86400))

tmpl=$(cu_eta_template_seven_day 70 $secs_to_reset 2>/dev/null)
assert_nonzero "template returns output with 4 weeks of data" "$tmpl"

if [ -n "$tmpl" ]; then
    read -r t_secs t_flag <<< "$tmpl"
    # Cap-hit projected somewhere between Mon end-of-day and Fri end-of-day.
    # Mon 17:00 = 28800s, Fri 17:00 = 4*86400 + 28800 = 374400s.
    assert_range "template projects cap-hit before reset" "28800" "374400" "$t_secs"
    assert_eq "template flags before-reset hit" "1" "$t_flag"
fi

# At Saturday 02:00 with low util, template should NOT predict cap before
# reset (no consumption in upcoming weekend hours, weekly reset Sun midnight).
sat_0200=$(date -d "2026-01-03 02:00:00" +%s 2>/dev/null || gdate -d "2026-01-03 02:00:00" +%s)
export CU_NOW=$sat_0200
# Reset on Sunday midnight (~22h from now); util only 5%
secs_to_reset=$((22 * 3600))

tmpl=$(cu_eta_template_seven_day 5 $secs_to_reset 2>/dev/null)
assert_nonzero "template returns output for weekend window" "$tmpl"

if [ -n "$tmpl" ]; then
    read -r t_secs t_flag <<< "$tmpl"
    assert_eq "weekend low-util: no cap-hit projected" "0" "${t_secs}"
    assert_eq "weekend low-util: before-reset flag empty" "" "${t_flag:-}"
fi

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
