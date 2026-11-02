#!/usr/bin/env bash
# test-pace.sh — Unit tests for pacing metric and limits suppression
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"

echo "=== Limits Suppression Tests ==="

CU_NO_LIMITS=1 ANTHROPIC_BASE_URL="" cu_limits_disabled && res=0 || res=1
assert_eq "CU_NO_LIMITS=1 disables limits" 0 "$res"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="http://127.0.0.1:4000" cu_limits_disabled && res=0 || res=1
assert_eq "LiteLLM endpoint disables limits" 0 "$res"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="https://openrouter.ai/api" cu_limits_disabled && res=0 || res=1
assert_eq "OpenRouter endpoint disables limits" 0 "$res"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="" cu_limits_disabled && res=0 || res=1
assert_eq "Default Anthropic endpoint allows limits" 1 "$res"

CU_NO_LIMITS="" ANTHROPIC_BASE_URL="https://api.anthropic.com" cu_limits_disabled && res=0 || res=1
assert_eq "api.anthropic.com allows limits" 1 "$res"

echo ""
echo "=== Work-Hours Target Curve Tests ==="

# Reset: Mon 2026-05-18 07:00 CEST (1779080400)
RESET_TS=1779080400
export ANTHROPIC_BASE_URL=""
export CU_NO_LIMITS=""

# Monday 07:00 CEST -> target 0%
CU_NOW=1778475600 cu_pace_load "0" "$RESET_TS"
assert_eq "Mon 07:00 target is 0%" "0" "$_CU_PACE_TARGET"
assert_eq "0% util on 0% target is ±0.0 overshoot" "0.0" "$_CU_PACE_OVERSHOOT"

# Tuesday 16:00 CEST -> target 40%
CU_NOW=1778594400 cu_pace_load "40" "$RESET_TS"
assert_eq "Tue 16:00 target is 40%" "40" "$_CU_PACE_TARGET"
assert_eq "40% util on 40% target is ±0.0 overshoot" "0.0" "$_CU_PACE_OVERSHOOT"

# Wednesday 16:00 CEST -> target 60%
CU_NOW=1778680800 cu_pace_load "75" "$RESET_TS"
assert_eq "Wed 16:00 target is 60%" "60" "$_CU_PACE_TARGET"
assert_eq "75% util on 60% target is +15.0 overshoot" "15.0" "$_CU_PACE_OVERSHOOT"

# Friday 16:00 CEST -> target 100%
CU_NOW=1778853600 cu_pace_load "80" "$RESET_TS"
assert_eq "Fri 16:00 target is 100%" "100" "$_CU_PACE_TARGET"
assert_eq "80% util on 100% target is -20.0 overshoot" "-20.0" "$_CU_PACE_OVERSHOOT"

echo ""
echo "=== Configurable Work Week ==="

assert_eq "default days" "[1,2,3,4,5]" "$(cu_pace_work_days mon-fri)"
assert_eq "day list" "[1,2,4]" "$(cu_pace_work_days mon,tue,thu)"
assert_eq "ISO numbers (7 = Sunday)" "[1,2,3,4,5,6,0]" "$(cu_pace_work_days 1-7)"
assert_eq "range wraps the week" "[5,6,0,1]" "$(cu_pace_work_days fri-mon)"
assert_eq "full day names" "[0,6]" "$(cu_pace_work_days Sunday,Saturday)"
assert_status "bad day name fails" 1 cu_pace_work_days mon-funday

# Same reset (Mon 07:00), Tue 16:00: with Mon-Thu 09-17 (32h/week),
# 1h of Tue + 8h Wed + 8h Thu = 17h left -> target 47%.
CU_PACE_WORK_DAYS=mon-thu CU_PACE_WORK_HOURS=09-17 CU_NOW=1778594400 cu_pace_load "40" "$RESET_TS"
assert_eq "Mon-Thu 09-17 target" "47" "$_CU_PACE_TARGET"
assert_eq "Mon-Thu 09-17 overshoot" "-7.0" "$_CU_PACE_OVERSHOOT"

# Every hour of the week counts: a straight line from reset to reset.
# Tue 16:00 is 33h after Mon 07:00 -> 33/168 = 20%.
CU_PACE_WORK_DAYS=mon-sun CU_PACE_WORK_HOURS=00-24 CU_NOW=1778594400 cu_pace_load "20" "$RESET_TS"
assert_eq "24/7 curve is linear" "20" "$_CU_PACE_TARGET"

CU_PACE_WORK_HOURS=16-07 cu_pace_load "20" "$RESET_TS" && res=0 || res=1
assert_eq "end before start is rejected" "1" "$res"

CU_PACE_ENABLED=0 cu_pace_load "20" "$RESET_TS" && res=0 || res=1
assert_eq "CU_PACE_ENABLED=0 disables pacing" "1" "$res"

echo ""
echo "=== External Contract Fallback ==="
export CU_PACE_CONTRACT_PATH="$TEST_DIR/contract.json"
echo '{"util":50,"target":45,"updated_at":1778594400}' > "$CU_PACE_CONTRACT_PATH"
CU_NOW=1778594460 cu_pace_load "" ""
assert_eq "contract file used without usage data" "5.0" "$_CU_PACE_OVERSHOOT"
CU_NOW=1778600000 cu_pace_load "" "" && res=0 || res=1
assert_eq "stale contract ignored" "1" "$res"
unset CU_PACE_CONTRACT_PATH

echo ""
echo "=== Formatting and Rendering Tests ==="

# Test overshoot formatting (the value comes in tenths of a point)
_CU_PACE_O10=0
_CU_PACE_COLOR=""
assert_eq "overshoot 0.0 formats as ±0 pts on curve" "±0 pts on curve" "$(cu_pace_fmt_overshoot)"

_CU_PACE_O10=124
assert_eq "overshoot +12.4 formats as +12 pts over" "+12 pts over" "$(cu_pace_fmt_overshoot)"

_CU_PACE_O10=-56
assert_eq "overshoot -5.6 formats as -6 pts under" "-6 pts under" "$(cu_pace_fmt_overshoot)"

_CU_PACE_O10=9
assert_eq "overshoot +0.9 is still on curve" "±0 pts on curve" "$(cu_pace_fmt_overshoot)"

# Test suppression in pace load
CU_NO_LIMITS=1 cu_pace_load "50" "$RESET_TS" && res=0 || res=1
assert_eq "cu_pace_load bails when CU_NO_LIMITS=1" 1 "$res"

# Test multiline rendering format. CU_NOW is Tue 16:00 (target 40%).
export CU_NOW=1778594400
export ANTHROPIC_BASE_URL=""
export CU_NO_LIMITS=""
strip() { sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n'; }

cu_pace_load "40" "$RESET_TS"
assert_eq "auto row is hidden on the curve" "" "$(cu_pace_render_multiline "")"
clean_out=$(CU_PACE_ROW=1 cu_pace_render_multiline "" | strip)
assert_eq "CU_PACE_ROW=1 shows the row on the curve" "pa ░░░░░░░░░░  ±0 pts on curve" "$clean_out"
assert_eq "CU_PACE_ROW=0 hides the row" "" "$(CU_PACE_ROW=0 cu_pace_render_multiline "")"

cu_pace_load "45" "$RESET_TS"
clean_out=$(cu_pace_render_multiline "" | strip)
assert_eq "auto row shows when over the curve" "pa █░░░░░░░░░  +5 pts over" "$clean_out"
clean_out=$(cu_pace_render_inline "" | strip)
assert_eq "inline segment" " | pace: +5 pts over" "$clean_out"

# Verify no pacing mechanism strings appear
echo "$clean_out" | grep -qE "pacing off|throttle|blocking" && has_mech=1 || has_mech=0
assert_eq "no pacing mechanism states in output" 0 "$has_mech"

echo ""
echo "=== Level (warn, crit) and Projection ==="

cu_pace_load "40" "$RESET_TS";   assert_eq "on the curve is ok" "ok" "$_CU_PACE_LEVEL"
cu_pace_load "40.5" "$RESET_TS"; assert_eq "under 1 point over is ok" "ok" "$_CU_PACE_LEVEL"
cu_pace_load "45" "$RESET_TS";   assert_eq "5 points over is warn" "warn" "$_CU_PACE_LEVEL"
cu_pace_load "50" "$RESET_TS";   assert_eq "10 points over is warn" "warn" "$_CU_PACE_LEVEL"
cu_pace_load "51" "$RESET_TS";   assert_eq "11 points over is crit" "crit" "$_CU_PACE_LEVEL"
cu_pace_load "45" "$RESET_TS" 1; assert_eq "5 points over with a projected cap hit is crit" "crit" "$_CU_PACE_LEVEL"
cu_pace_load "30" "$RESET_TS" 1; assert_eq "under the curve stays ok with a projected hit" "ok" "$_CU_PACE_LEVEL"
cu_pace_load "45" "$RESET_TS";   cu_pace_classify 1
assert_eq "classify later raises the level" "crit" "$_CU_PACE_LEVEL"

echo ""
echo "=== Model Hint ==="

OPUS="claude-opus-5-5 Opus 5.5"
SONNET="claude-sonnet-5-5 Sonnet 5.5"
cu_pace_load "60" "$RESET_TS"   # 20 points over: crit
assert_eq "heavy model over the curve warns" "⚠ opus: try sonnet" "$(cu_pace_model_hint "$OPUS")"
assert_eq "light model gets no hint" "" "$(cu_pace_model_hint "$SONNET")"
assert_eq "unknown model gets no hint" "" "$(cu_pace_model_hint " ")"
assert_eq "hint off" "" "$(CU_PACE_MODEL_HINT=0 cu_pace_model_hint "$OPUS")"
assert_eq "heavy list is configurable" "⚠ sonnet: try haiku" \
    "$(CU_PACE_HEAVY_MODELS=sonnet CU_PACE_LIGHT_MODEL=haiku cu_pace_model_hint "$SONNET")"
assert_eq "display name matches too" "⚠ fable: try sonnet" "$(cu_pace_model_hint "x Fable 5.1")"
cu_pace_load "45" "$RESET_TS"   # 5 points over: warn
assert_eq "mild overshoot on a heavy model is a dim hint" "→ sonnet" "$(cu_pace_model_hint "$OPUS")"
cu_pace_load "40" "$RESET_TS"
assert_eq "no hint on the curve" "" "$(cu_pace_model_hint "$OPUS")"
cu_pace_load "60" "$RESET_TS"
clean_out=$(cu_pace_render_multiline "$OPUS" | strip)
assert_eq "hint shows in the row" "pa ██████░░░░  +20 pts over ⚠ opus: try sonnet" "$clean_out"
cu_pace_load "40" "$RESET_TS"
assert_eq "no hint row on the curve in auto mode" "" "$(cu_pace_render_multiline "$OPUS")"

echo ""
echo "=== Target Max and Off Dates ==="

# Tue 16:00: 40% of the week has passed.
CU_PACE_TARGET_MAX=90 cu_pace_load "0" "$RESET_TS"
assert_eq "target max 90 scales the curve" "36" "$_CU_PACE_TARGET"
CU_NOW=1778853600 CU_PACE_TARGET_MAX=90 cu_pace_load "0" "$RESET_TS"
assert_eq "the curve ends at target max" "90" "$_CU_PACE_TARGET"
# Wed 2026-05-13 is off: the week has 36 work hours and 18 have passed by Tue 16:00.
CU_PACE_OFF_DATES="2026-05-13" cu_pace_load "0" "$RESET_TS"
assert_eq "an off day removes its hours from the week" "50" "$_CU_PACE_TARGET"
CU_PACE_OFF_DATES="2026-05-11,2026-05-12,2026-05-13,2026-05-14,2026-05-15" cu_pace_load "0" "$RESET_TS" && res=0 || res=1
assert_eq "a week of off days has no curve" "1" "$res"

assert_done
