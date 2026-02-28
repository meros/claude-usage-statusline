#!/usr/bin/env bash
# test-history.sh - History write/read/prune tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use temp dirs for isolation
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CU_DATA_DIR="$TEST_DIR/data"
export CU_CACHE_DIR="$TEST_DIR/cache"
export CU_NO_COLOR=1

source "${SCRIPT_DIR}/../lib/util.sh"
source "${SCRIPT_DIR}/../lib/fetch.sh"
source "${SCRIPT_DIR}/../lib/history.sh"

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

echo "=== History Record Tests ==="

# Record a snapshot
export CU_NOW=1709100000
data='{"five_hour":{"utilization":10,"resets_at":"2025-03-01T14:00:00Z"},"seven_day":{"utilization":30,"resets_at":"2025-03-06T00:00:00Z"}}'
cu_history_record "$data"

lines=$(wc -l < "$CU_HISTORY_FILE")
assert_eq "first record creates 1 line" "1" "$lines"

# Same hour: should deduplicate
export CU_NOW=1709100100
cu_history_record "$data"
lines=$(wc -l < "$CU_HISTORY_FILE")
assert_eq "same hour deduplicates" "1" "$lines"

# Next hour: should append
export CU_NOW=1709103600
cu_history_record "$data"
lines=$(wc -l < "$CU_HISTORY_FILE")
assert_eq "next hour appends" "2" "$lines"

echo ""
echo "=== History Read Tests ==="

# Read back last 24 hours
export CU_NOW=1709103600
count=$(cu_history_read 24 | wc -l)
assert_eq "read last 24h gets 2 entries" "2" "$count"

# Read values
val=$(cu_history_values "seven_day" 24 | head -1)
assert_eq "seven_day util value" "30" "$val"

echo ""
echo "=== History Prune Tests ==="

# Add an old entry manually
echo '{"ts":1707800000,"five_hour":{"util":5,"resets_at":""},"seven_day":{"util":10,"resets_at":""}}' >> "$CU_HISTORY_FILE"
lines_before=$(wc -l < "$CU_HISTORY_FILE")

export CU_NOW=1709103600
cu_history_prune
lines_after=$(wc -l < "$CU_HISTORY_FILE")

assert_eq "prune removes old entries" "2" "$lines_after"

echo ""
echo "=== Missing Seven-Day Window Tests ==="

# Record data with only five_hour (no weekly limit)
> "$CU_HISTORY_FILE"
export CU_NOW=1709200000
data_five_only='{"five_hour":{"utilization":25,"resets_at":"2025-03-01T14:00:00Z"}}'
cu_history_record "$data_five_only"
lines=$(wc -l < "$CU_HISTORY_FILE")
assert_eq "five_hour-only record creates 1 line" "1" "$lines"

# Verify five_hour data is present
val=$(cu_history_values "five_hour" 24 | head -1)
assert_eq "five_hour util recorded" "25" "$val"

# Verify seven_day is absent (jq returns null)
has_seven=$(jq -r '.seven_day // empty' "$CU_HISTORY_FILE" | head -1)
assert_eq "seven_day absent in five_hour-only record" "" "$has_seven"

# Record data with only seven_day (no session limit — hypothetical)
> "$CU_HISTORY_FILE"
export CU_NOW=1709200000
data_seven_only='{"seven_day":{"utilization":40,"resets_at":"2025-03-06T00:00:00Z"}}'
cu_history_record "$data_seven_only"

val=$(cu_history_values "seven_day" 24 | head -1)
assert_eq "seven_day util recorded when five_hour absent" "40" "$val"

has_five=$(jq -r '.five_hour // empty' "$CU_HISTORY_FILE" | head -1)
assert_eq "five_hour absent in seven_day-only record" "" "$has_five"

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
