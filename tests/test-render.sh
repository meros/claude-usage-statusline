#!/usr/bin/env bash
# test-render.sh - Sparkline + bar rendering tests
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"

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
assert_eq "sparkline single 50 (auto-scaled to max)" "█" "$result"

# Auto-scaling: low-range values should show variation
result=$(CU_OPT_WIDTH=4 cu_sparkline 0 5 10 15)
assert_eq "sparkline auto-scale low range" "▁▃▅█" "$result"

echo ""
echo "=== Braille Sparkline Tests ==="

# Braille sparkline: pairs of values encoded per char
# 0,0 -> empty braille U+2800
result=$(cu_braille_sparkline 0 0)
assert_eq "braille zeros" "⠀" "$result"

# 100,100 -> full 8-dot braille (all dots = 0xFF)
result=$(cu_braille_sparkline 100 100)
assert_eq "braille full" "⣿" "$result"

# 4 values = 2 braille chars
result=$(cu_braille_sparkline 0 0 100 100)
assert_eq "braille 4 values length" 2 "$(cu_visible_len "$result")"

echo ""
echo "=== Progress Bar Tests ==="

# Progress bar (no-color mode for predictable output)
result=$(cu_progress_bar 0 10)
assert_eq "bar 0%" "░░░░░░░░░░" "$result"

result=$(cu_progress_bar 100 10)
assert_eq "bar 100%" "██████████" "$result"

result=$(cu_progress_bar 50 10)
assert_eq "bar 50%" "█████░░░░░" "$result"

result=$(cu_progress_bar 150 4)
assert_eq "bar clamps above 100" "████" "$result"

result=$(CU_NO_COLOR="" cu_progress_bar 50 2 "1;2")
assert_eq "bar takes a custom color" $'\033[1;2m█\033[38;2;146;131;116m░\033[0m' "$result"

echo ""
echo "=== Value Formatting ==="
assert_eq "pct" "69%" "$(cu_fmt_pct 69.4)"
assert_eq "rate one decimal" "9.5" "$(cu_fmt_rate 9.5000)"
assert_eq "rate per hour window" "10%/1h" "$(cu_fmt_rate_per_window 9.5 1)"
assert_eq "rate per day window" "19%/1d" "$(cu_fmt_rate_per_window 0.7792 24)"
assert_eq "rate per 6h window" "5%/6h" "$(cu_fmt_rate_per_window 0.8 6)"
export CU_NOW=1791525600
assert_eq "5h ETA is a duration" "1h 0m" "$(cu_fmt_eta five_hour 3600)"
assert_eq "7d ETA is a day and hour" "Fri 9am" "$(cu_fmt_eta seven_day 3600)"
assert_eq "ETA before reset -> red" "$CU_RED" "$(cu_eta_color 1800 2026-10-09T07:00:00Z)"
assert_eq "ETA just after reset -> yellow" "$CU_YELLOW" "$(cu_eta_color 4000 2026-10-09T07:00:00Z)"
assert_eq "ETA well after reset -> green" "$CU_GREEN" "$(cu_eta_color 9000 2026-10-09T07:00:00Z)"
unset CU_NOW

echo ""
echo "=== Sparkline From History ==="
# Utilization grows 5 points per 30 min for 2.5 hours, then resets.
: > "$CU_HISTORY_SHORT"
for i in 0 1 2 3 4 5 6 7; do
    ts=$((1700000000 + i * 1800))
    if [ "$i" -lt 6 ]; then val=$((i * 5)); ra="2023-11-14T23:00:00Z"; else val=0; ra="2023-11-15T04:00:00Z"; fi
    echo "{\"ts\":$ts,\"five_hour\":{\"util\":$val,\"resets_at\":\"$ra\"}}" >> "$CU_HISTORY_SHORT"
done
export CU_NOW=$((1700000000 + 4 * 3600))
result=$(cu_sparkline_from_history five_hour 4 8 "" short)
assert_eq "block sparkline of growth per slot" "█████▁▁▁" "$result"
result=$(cu_sparkline_from_history five_hour 4 4 braille short)
assert_contains "braille sparkline marks the reset" "↻" "$result"
assert_eq "braille sparkline width" "4" "$(cu_visible_len "$result")"
assert_eq "no history -> empty" "" "$(cu_sparkline_from_history seven_day 4 8 "" long)"
unset CU_NOW

result=$(CU_SPARK_RESETS="2" cu_braille_sparkline 4 4 4 4 4 4)
assert_eq "reset index replaces its cell" "⣿↻⣿" "$result"

echo ""
echo "=== Percentage Color Tests ==="

color=$(cu_pct_color 20)
assert_eq "20% -> green" "$CU_GREEN" "$color"

color=$(cu_pct_color 60)
assert_eq "60% -> yellow" "$CU_YELLOW" "$color"

color=$(cu_pct_color 90)
assert_eq "90% -> red" "$CU_RED" "$color"

assert_done
