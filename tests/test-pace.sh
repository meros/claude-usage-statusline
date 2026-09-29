#!/usr/bin/env bash
# test-pace.sh — Unit tests for pacing metric and limits suppression
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

export CU_NO_COLOR=1
export NO_COLOR=1

source "${LIB_DIR}/util.sh"
source "${LIB_DIR}/pace.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $msg"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Limits Suppression Tests ==="

CU_NO_LIMITS=1 ANTHROPIC_BASE_URL="" cu_limits_disabled && res=0 || res=1
assert_eq 0 "$res" "CU_NO_LIMITS=1 disables limits"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="http://127.0.0.1:4000" cu_limits_disabled && res=0 || res=1
assert_eq 0 "$res" "LiteLLM endpoint disables limits"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="https://openrouter.ai/api" cu_limits_disabled && res=0 || res=1
assert_eq 0 "$res" "OpenRouter endpoint disables limits"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="" cu_limits_disabled && res=0 || res=1
assert_eq 1 "$res" "Default Anthropic endpoint allows limits"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="https://api.anthropic.com" cu_limits_disabled && res=0 || res=1
assert_eq 1 "$res" "api.anthropic.com allows limits"

echo ""
echo "=== Work-Hours Target Curve Tests ==="

# Reset: Mon 2026-05-18 07:00 CEST (1779080400)
RESET_TS=1779080400
export ANTHROPIC_BASE_URL=""
export CU_NO_LIMITS=""

# Monday 07:00 CEST -> target 0%
CU_NOW=1778475600 cu_pace_load "0" "$RESET_TS"
assert_eq "0" "$_CU_PACE_TARGET" "Mon 07:00 target is 0%"
assert_eq "0.0" "$_CU_PACE_OVERSHOOT" "0% util on 0% target is ±0.0 overshoot"

# Tuesday 16:00 CEST -> target 40%
CU_NOW=1778594400 cu_pace_load "40" "$RESET_TS"
assert_eq "40" "$_CU_PACE_TARGET" "Tue 16:00 target is 40%"
assert_eq "0.0" "$_CU_PACE_OVERSHOOT" "40% util on 40% target is ±0.0 overshoot"

# Wednesday 16:00 CEST -> target 60%
CU_NOW=1778680800 cu_pace_load "75" "$RESET_TS"
assert_eq "60" "$_CU_PACE_TARGET" "Wed 16:00 target is 60%"
assert_eq "15.0" "$_CU_PACE_OVERSHOOT" "75% util on 60% target is +15.0 overshoot"

# Friday 16:00 CEST -> target 100%
CU_NOW=1778853600 cu_pace_load "80" "$RESET_TS"
assert_eq "100" "$_CU_PACE_TARGET" "Fri 16:00 target is 100%"
assert_eq "-20.0" "$_CU_PACE_OVERSHOOT" "80% util on 100% target is -20.0 overshoot"

echo ""
echo "=== Formatting and Rendering Tests ==="

# Test overshoot formatting
_CU_PACE_OVERSHOOT="0.0"
_CU_PACE_COLOR=""
assert_eq "±0% on curve" "$(cu_pace_fmt_overshoot)" "overshoot 0.0 formats as ±0% on curve"

_CU_PACE_OVERSHOOT="12.4"
assert_eq "+12% over" "$(cu_pace_fmt_overshoot)" "overshoot +12.4 formats as +12% over"

_CU_PACE_OVERSHOOT="-5.6"
assert_eq "-6% under" "$(cu_pace_fmt_overshoot)" "overshoot -5.6 formats as -6% under"

# Test suppression in pace load
CU_NO_LIMITS=1 cu_pace_load "50" "$RESET_TS" && res=0 || res=1
assert_eq 1 "$res" "cu_pace_load bails when CU_NO_LIMITS=1"

# Test multiline rendering format
export CU_NOW=1778594400
export ANTHROPIC_BASE_URL=""
export CU_NO_LIMITS=""
out=$(cu_pace_render_multiline "40" "$RESET_TS")
clean_out=$(echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n')
echo "$clean_out" | grep -q "pa ░░░░░░░░░░  ±0% on curve" && has_pa=1 || has_pa=0
assert_eq 1 "$has_pa" "cu_pace_render_multiline output matches expected format"

# Verify no pacing mechanism strings appear
echo "$clean_out" | grep -qE "pacing off|throttle|blocking" && has_mech=1 || has_mech=0
assert_eq 0 "$has_mech" "no pacing mechanism states in output"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
