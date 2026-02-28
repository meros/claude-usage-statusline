#!/usr/bin/env bash
# test-history.sh - Dual-tier history write/read/prune/migration tests
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

echo "=== Short Tier (5-min Dedup) Tests ==="

export CU_NOW=1709100000
data='{"five_hour":{"utilization":10,"resets_at":"2025-03-01T14:00:00Z"},"seven_day":{"utilization":30,"resets_at":"2025-03-06T00:00:00Z"}}'
cu_history_record "$data"

lines=$(wc -l < "$CU_HISTORY_SHORT")
assert_eq "first record creates 1 short entry" "1" "$lines"

# Same 5-min bucket: should deduplicate
export CU_NOW=1709100100
cu_history_record "$data"
lines=$(wc -l < "$CU_HISTORY_SHORT")
assert_eq "same 5-min bucket deduplicates short" "1" "$lines"

# Next 5-min bucket: should append
export CU_NOW=1709100300
cu_history_record "$data"
lines=$(wc -l < "$CU_HISTORY_SHORT")
assert_eq "next 5-min bucket appends short" "2" "$lines"

# Verify short file only has five_hour, not seven_day
has_seven=$(jq -r '.seven_day // empty' "$CU_HISTORY_SHORT" | head -1)
assert_eq "short file has no seven_day" "" "$has_seven"
val=$(jq -r '.five_hour.util' "$CU_HISTORY_SHORT" | head -1)
assert_eq "short file has five_hour util" "10" "$val"

echo ""
echo "=== Long Tier (Hourly Dedup) Tests ==="

lines=$(wc -l < "$CU_HISTORY_LONG")
assert_eq "first record creates 1 long entry" "1" "$lines"

# Same hour: should deduplicate
export CU_NOW=1709100300
cu_history_record "$data"
lines=$(wc -l < "$CU_HISTORY_LONG")
assert_eq "same hour deduplicates long" "1" "$lines"

# Next hour: should append
export CU_NOW=1709103600
cu_history_record "$data"
lines=$(wc -l < "$CU_HISTORY_LONG")
assert_eq "next hour appends long" "2" "$lines"

# Verify long file only has seven_day, not five_hour
has_five=$(jq -r '.five_hour // empty' "$CU_HISTORY_LONG" | head -1)
assert_eq "long file has no five_hour" "" "$has_five"
val=$(jq -r '.seven_day.util' "$CU_HISTORY_LONG" | head -1)
assert_eq "long file has seven_day util" "30" "$val"

echo ""
echo "=== History Read Tests ==="

export CU_NOW=1709103600
count=$(cu_history_read "short" 24 | wc -l)
assert_eq "read short last 24h gets entries" "3" "$count"

count=$(cu_history_read "long" 24 | wc -l)
assert_eq "read long last 24h gets entries" "2" "$count"

# Read values
val=$(cu_history_values "short" "five_hour" 24 | head -1)
assert_eq "short tier five_hour util value" "10" "$val"

val=$(cu_history_values "long" "seven_day" 24 | head -1)
assert_eq "long tier seven_day util value" "30" "$val"

echo ""
echo "=== History Prune Tests ==="

# Add old entry to short (>24h old, should be pruned)
echo '{"ts":1707800000,"five_hour":{"util":5,"resets_at":""}}' >> "$CU_HISTORY_SHORT"
# Add truly old entry to long (>1 year old, should be pruned)
echo '{"ts":1670000000,"seven_day":{"util":10,"resets_at":""}}' >> "$CU_HISTORY_LONG"

short_before=$(wc -l < "$CU_HISTORY_SHORT")
long_before=$(wc -l < "$CU_HISTORY_LONG")

export CU_NOW=1709103600
cu_history_prune

short_after=$(wc -l < "$CU_HISTORY_SHORT")
long_after=$(wc -l < "$CU_HISTORY_LONG")

assert_eq "prune removes old short entries" "3" "$short_after"
assert_eq "prune removes old long entries" "2" "$long_after"

echo ""
echo "=== Missing Fields Don't Create Wrong Tier Entries ==="

# Reset files
rm -f "$CU_HISTORY_SHORT" "$CU_HISTORY_LONG"
export CU_NOW=1709200000

# Record data with only five_hour (no weekly limit)
data_five_only='{"five_hour":{"utilization":25,"resets_at":"2025-03-01T14:00:00Z"}}'
cu_history_record "$data_five_only"

assert_eq "five_hour-only creates short file" "1" "$([ -f "$CU_HISTORY_SHORT" ] && echo 1 || echo 0)"
assert_eq "five_hour-only does not create long file" "0" "$([ -f "$CU_HISTORY_LONG" ] && echo 1 || echo 0)"

val=$(cu_history_values "short" "five_hour" 24 | head -1)
assert_eq "five_hour util recorded in short" "25" "$val"

# Record data with only seven_day
rm -f "$CU_HISTORY_SHORT" "$CU_HISTORY_LONG"
export CU_NOW=1709200000
data_seven_only='{"seven_day":{"utilization":40,"resets_at":"2025-03-06T00:00:00Z"}}'
cu_history_record "$data_seven_only"

assert_eq "seven_day-only does not create short file" "0" "$([ -f "$CU_HISTORY_SHORT" ] && echo 1 || echo 0)"
assert_eq "seven_day-only creates long file" "1" "$([ -f "$CU_HISTORY_LONG" ] && echo 1 || echo 0)"

val=$(cu_history_values "long" "seven_day" 24 | head -1)
assert_eq "seven_day util recorded in long" "40" "$val"

echo ""
echo "=== Migration Tests ==="

# Set up old-style history.jsonl
rm -f "$CU_HISTORY_SHORT" "$CU_HISTORY_LONG"
export CU_NOW=1709103600
local_old="${CU_DATA_DIR}/history.jsonl"

# Write entries spanning >24h for migration boundary testing
cat > "$local_old" <<'JSONL'
{"ts":1709000000,"five_hour":{"util":5,"resets_at":""},"seven_day":{"util":10,"resets_at":""}}
{"ts":1709050000,"five_hour":{"util":15,"resets_at":""},"seven_day":{"util":20,"resets_at":""}}
{"ts":1709100000,"five_hour":{"util":25,"resets_at":""},"seven_day":{"util":30,"resets_at":""}}
JSONL

cu_history_migrate

assert_eq "migration creates short file" "1" "$([ -f "$CU_HISTORY_SHORT" ] && echo 1 || echo 0)"
assert_eq "migration creates long file" "1" "$([ -f "$CU_HISTORY_LONG" ] && echo 1 || echo 0)"
assert_eq "migration creates backup" "1" "$([ -f "${local_old}.bak" ] && echo 1 || echo 0)"
assert_eq "migration removes original" "0" "$([ -f "$local_old" ] && echo 1 || echo 0)"

# Short should only have entries within 24h of CU_NOW (1709103600)
# Cutoff = 1709103600 - 86400 = 1709017200
# ts=1709000000 is before cutoff, ts=1709050000 and ts=1709100000 are after
short_count=$(wc -l < "$CU_HISTORY_SHORT")
assert_eq "migration short has last-24h entries" "2" "$short_count"

# Long should have all entries with seven_day
long_count=$(wc -l < "$CU_HISTORY_LONG")
assert_eq "migration long has all entries" "3" "$long_count"

# Short entries should only have five_hour field
has_seven_in_short=$(jq -r '.seven_day // empty' "$CU_HISTORY_SHORT" | head -1)
assert_eq "migrated short has no seven_day" "" "$has_seven_in_short"

# Long entries should only have seven_day field
has_five_in_long=$(jq -r '.five_hour // empty' "$CU_HISTORY_LONG" | head -1)
assert_eq "migrated long has no five_hour" "" "$has_five_in_long"

# Idempotent: running migrate again should be a no-op
cu_history_migrate
short_count2=$(wc -l < "$CU_HISTORY_SHORT")
assert_eq "migration is idempotent" "$short_count" "$short_count2"

echo ""
echo "=== Dump Tests ==="

dump_output=$(cu_history_dump)
assert_eq "dump shows short header" "1" "$(echo "$dump_output" | grep -c 'Short tier' || true)"
assert_eq "dump shows long header" "1" "$(echo "$dump_output" | grep -c 'Long tier' || true)"

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
