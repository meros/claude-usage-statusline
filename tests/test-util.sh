#!/usr/bin/env bash
# shellcheck disable=SC2154  # _win_* are set by cu_window_config
# test-util.sh - Paths, time and formatting helpers, config defaults
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"

echo "=== Paths ==="
CU_DATA_DIR="$TEST_DIR/d2" CU_CACHE_DIR="$TEST_DIR/c2"
cu_set_paths
assert_eq "history path follows CU_DATA_DIR" "$TEST_DIR/d2/history-long.jsonl" "$CU_HISTORY_LONG"
assert_eq "backoff path follows CU_CACHE_DIR" "$TEST_DIR/c2/rate-limit-backoff" "$CU_BACKOFF_FILE"
assert_eq "lock path follows CU_CACHE_DIR" "$TEST_DIR/c2/fetch.lock" "$CU_FETCH_LOCK"
[ -d "$TEST_DIR/d2" ] && [ -d "$TEST_DIR/c2" ] && result=yes || result=no
assert_eq "cu_set_paths creates the directories" "yes" "$result"

echo ""
echo "=== Clock ==="
assert_eq "CU_NOW overrides the clock" "1234" "$(CU_NOW=1234 cu_now)"
touch -d "@1000" "$TEST_DIR/f"
assert_eq "file mtime" "1000" "$(cu_file_mtime "$TEST_DIR/f")"
assert_eq "file age relative to CU_NOW" "500" "$(CU_NOW=1500 cu_file_age "$TEST_DIR/f")"
assert_eq "missing file mtime is 0" "0" "$(cu_file_mtime "$TEST_DIR/none")"
assert_eq "ISO to epoch" "1791529200" "$(cu_iso_to_epoch 2026-10-09T07:00:00Z)"
assert_eq "ISO with fraction to epoch" "1791529200" "$(cu_iso_to_epoch 2026-10-09T07:00:00.123456+00:00)"
assert_eq "seconds until reset" "3600" "$(CU_NOW=1791525600 cu_secs_until_reset 2026-10-09T07:00:00Z)"
assert_eq "empty reset is 0" "0" "$(cu_secs_until_reset "")"

echo ""
echo "=== Formatting ==="
assert_eq "duration minutes" "5m" "$(cu_fmt_duration 300)"
assert_eq "duration hours" "1h 1m" "$(cu_fmt_duration 3661)"
assert_eq "duration days" "1d 1h" "$(cu_fmt_duration 90061)"
assert_eq "negative duration is now" "now" "$(cu_fmt_duration -5)"
assert_eq "reset date in local time" "Fri 9am" "$(cu_fmt_reset_date 2026-10-09T07:00:00Z)"
assert_eq "afternoon reset date" "Wed 3pm" "$(cu_fmt_reset_date 2026-10-07T13:40:00Z)"
assert_eq "ETA date" "Fri 9am" "$(CU_NOW=1791525600 cu_fmt_eta_date 3600)"
assert_eq "visible length ignores ANSI" "3" "$(cu_visible_len $'\033[38;2;1;2;3mabc\033[0m')"
assert_eq "visible length counts characters" "4" "$(cu_visible_len "⣿⣿↻█")"
assert_eq "comma list to words" "a b c" "$(cu_words a,b,c)"

echo ""
echo "=== Colors ==="
assert_eq "no color: cu_color prints nothing" "" "$(cu_color "$CU_RED")"
assert_eq "color on" $'\033[1;2m' "$(CU_NO_COLOR="" cu_color "1;2")"
assert_eq "49% -> green" "$CU_GREEN" "$(cu_pct_color 49)"
assert_eq "50% -> yellow" "$CU_YELLOW" "$(cu_pct_color 50)"
assert_eq "80% -> red" "$CU_RED" "$(cu_pct_color 80)"
assert_eq "float pct truncates" "$CU_YELLOW" "$(cu_pct_color 79.9)"
assert_eq "CU_PCT_WARN moves yellow" "$CU_YELLOW" "$(CU_PCT_WARN=20 cu_pct_color 25)"
assert_eq "CU_PCT_CRIT moves red" "$CU_RED" "$(CU_PCT_CRIT=60 cu_pct_color 65)"

echo ""
echo "=== Windows ==="
cu_window_config five_hour
assert_eq "five_hour label" "5h" "$_win_label"
assert_eq "five_hour rate window" "1" "$_win_avg"
assert_eq "five_hour tier" "short" "$_win_tier"
cu_window_config seven_day
assert_eq "seven_day label" "7d" "$_win_label"
assert_eq "seven_day sparkline hours" "168" "$_win_spark_hours"
assert_status "unknown window" 1 cu_window_config opus_weekly

echo ""
echo "=== Limits Suppression ==="
assert_status "CU_NO_LIMITS=1 disables limits" 0 env CU_NO_LIMITS=1 bash -c "source '$CU_LIB_DIR/util.sh'; source '$CU_LIB_DIR/config.sh'; cu_limits_disabled"
CU_HIDE_LIMITS=1 cu_limits_disabled && result=0 || result=1
assert_eq "CU_HIDE_LIMITS=1 disables limits" "0" "$result"
ANTHROPIC_BASE_URL=http://127.0.0.1:4000 cu_limits_disabled && result=0 || result=1
assert_eq "proxy endpoint disables limits" "0" "$result"
ANTHROPIC_BASE_URL=https://api.anthropic.com cu_limits_disabled && result=0 || result=1
assert_eq "Anthropic endpoint keeps limits" "1" "$result"
cu_limits_disabled && result=0 || result=1
assert_eq "no endpoint keeps limits" "1" "$result"

assert_done
