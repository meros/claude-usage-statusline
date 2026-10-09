#!/usr/bin/env bash
# pace.sh - Weekly budget pacing: is 7-day usage ahead of or behind the work week?
#
# The target curve spreads the weekly cap evenly over the work hours of the
# week (default Mon-Fri 07-16, 45 hours). At any moment the target is the
# share of this week's work hours that have passed:
#   target = 100 * (1 - work_hours_left_until_reset / work_hours_per_week)
# Overshoot = utilization - target. Positive means you burn faster than the
# work week allows. A pure metric: nothing is throttled or blocked.
#
# Settings:
#   CU_PACE_ENABLED     1 (default) or 0
#   CU_PACE_WORK_DAYS   days that count, e.g. "mon-fri", "mon,tue,thu", "1-5" (1 = Monday)
#   CU_PACE_WORK_HOURS  local hours that count, start-end, end exclusive: "07-16"
#   CU_PACE_BAR_SCALE   overshoot (points) that fills the bar (default 30)
#   CU_PACE_CONTRACT_PATH, CU_PACE_STALE_SECONDS
#                       JSON from an external pacer ({"util", "target", "updated_at"}),
#                       read only when no usage data is available

CU_PACE_ENABLED="${CU_PACE_ENABLED:-1}"
CU_PACE_WORK_DAYS="${CU_PACE_WORK_DAYS:-mon-fri}"
CU_PACE_WORK_HOURS="${CU_PACE_WORK_HOURS:-07-16}"
CU_PACE_BAR_SCALE="${CU_PACE_BAR_SCALE:-${CU_PACE_DENY_THRESHOLD:-30}}"
CU_PACE_CONTRACT_PATH="${CU_PACE_CONTRACT_PATH:-$HOME/.cache/claude-pacing/statusline.json}"
CU_PACE_STALE_SECONDS="${CU_PACE_STALE_SECONDS:-120}"

# Day name or number (1 = Monday ... 7 = Sunday) to jq weekday (0 = Sunday).
_cu_pace_day_num() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        sun*|0|7) echo 0 ;;
        mon*|1) echo 1 ;;
        tue*|2) echo 2 ;;
        wed*|3) echo 3 ;;
        thu*|4) echo 4 ;;
        fri*|5) echo 5 ;;
        sat*|6) echo 6 ;;
        *) return 1 ;;
    esac
}

# CU_PACE_WORK_DAYS as a JSON array of jq weekdays: "mon-fri" -> [1,2,3,4,5].
# Ranges wrap around the week: "fri-mon" -> [5,6,0,1].
cu_pace_work_days() {
    local spec="$1" item from to d out=""
    for item in $(cu_words "$spec"); do
        if [[ "$item" == *-* ]]; then
            from=$(_cu_pace_day_num "${item%%-*}") || return 1
            to=$(_cu_pace_day_num "${item#*-}") || return 1
            d="$from"
            while :; do
                out+="${out:+,}$d"
                [ "$d" = "$to" ] && break
                d=$(( (d + 1) % 7 ))
            done
        else
            d=$(_cu_pace_day_num "$item") || return 1
            out+="${out:+,}$d"
        fi
    done
    [ -n "$out" ] || return 1
    echo "[$out]"
}

# Target utilization (0-100) at NOW for a window that resets at RESET_EPOCH.
cu_pace_target() {
    local now="$1" reset_epoch="$2" days start end
    days=$(cu_pace_work_days "$CU_PACE_WORK_DAYS") || return 1
    start=$((10#${CU_PACE_WORK_HOURS%%-*}))
    end=$((10#${CU_PACE_WORK_HOURS#*-}))
    [ "$end" -gt "$start" ] || return 1

    jq -n --argjson now "$now" --argjson reset "$reset_epoch" \
        --argjson days "$days" --argjson start "$start" --argjson end "$end" '
        def is_work: localtime as $lt
            | ($days | index($lt[6])) != null and $lt[3] >= $start and $lt[3] < $end;
        (($days | unique | length) * ($end - $start)) as $per_week |
        (if $reset <= $now then 0
         else [range($now; $reset; 3600) | select(is_work)] | length end) as $left |
        ([0, (1 - $left / $per_week)] | max | [1, .] | min * 100) | round
    ' 2>/dev/null
}

# Compute the pacing metric into _CU_PACE_* globals:
#   _CU_PACE_UTIL, _CU_PACE_TARGET, _CU_PACE_OVERSHOOT (points), _CU_PACE_COLOR
# Args: seven_day utilization, seven_day reset (ISO or epoch). Without them it
# reads the cache, then the external contract file.
# Returns non-zero when there is nothing to show.
cu_pace_load() {
    _CU_PACE_UTIL=""
    _CU_PACE_TARGET=""
    _CU_PACE_OVERSHOOT=""
    _CU_PACE_COLOR=""

    [ "${CU_PACE_ENABLED:-1}" = "1" ] || return 1
    cu_limits_disabled && return 1

    local util="${1:-}" reset_val="${2:-}"
    if [ -z "$util" ] || [ -z "$reset_val" ]; then
        local cache_data
        cache_data=$(cu_read_cache 2>/dev/null)
        if [ -n "$cache_data" ]; then
            util=$(cu_get_seven_day_pct "$cache_data")
            reset_val=$(cu_get_seven_day_reset "$cache_data")
        fi
    fi

    if [ -n "$util" ] && [ -n "$reset_val" ]; then
        local reset_epoch target
        if [[ "$reset_val" =~ ^[0-9]+$ ]]; then
            reset_epoch="$reset_val"
        else
            reset_epoch=$(cu_iso_to_epoch "$reset_val") || return 1
        fi
        target=$(cu_pace_target "$(cu_now)" "$reset_epoch")
        [ -n "$target" ] || return 1
        _CU_PACE_UTIL="$util"
        _CU_PACE_TARGET="$target"
    elif [ -r "$CU_PACE_CONTRACT_PATH" ]; then
        local data updated_at
        data=$(cat "$CU_PACE_CONTRACT_PATH" 2>/dev/null)
        updated_at=$(echo "$data" | jq -r '.updated_at // 0' 2>/dev/null)
        [ $(( $(cu_now) - ${updated_at:-0} )) -le "$CU_PACE_STALE_SECONDS" ] || return 1
        _CU_PACE_UTIL=$(echo "$data" | jq -r '.util // 0' 2>/dev/null)
        _CU_PACE_TARGET=$(echo "$data" | jq -r '.target // 0' 2>/dev/null)
    else
        return 1
    fi

    _CU_PACE_OVERSHOOT=$(awk -v u="$_CU_PACE_UTIL" -v t="$_CU_PACE_TARGET" 'BEGIN { printf "%.1f", u - t }')
    # On or under the curve: green; up to 10 points over: yellow; more: red.
    _CU_PACE_COLOR=$(awk -v o="$_CU_PACE_OVERSHOOT" \
        -v g="$CU_GREEN" -v y="$CU_YELLOW" -v r="$CU_RED" '
        BEGIN { print (o <= 0) ? g : (o <= 10) ? y : r }')
    return 0
}

# "+12% over", "-6% under" or "±0% on curve" (within 1 point), colored.
cu_pace_fmt_overshoot() {
    local phrase
    phrase=$(awk -v v="$_CU_PACE_OVERSHOOT" 'BEGIN {
        a = (v < 0 ? -v : v);
        if (a < 1.0) { printf "±0%% on curve" }
        else if (v >= 0) { printf "+%.0f%% over", v }
        else { printf "-%.0f%% under", a }
    }')
    printf "%s%s%s" "$(cu_color "${_CU_PACE_COLOR:-$CU_GREEN}")" "$phrase" "$(cu_reset)"
}

# Overshoot as a bar: empty on or under the curve, full at CU_PACE_BAR_SCALE points over.
cu_pace_bar() {
    local pct
    pct=$(awk -v o="$_CU_PACE_OVERSHOOT" -v d="$CU_PACE_BAR_SCALE" \
        'BEGIN { v = (o < 0 ? 0 : o); p = (v * 100) / d; if (p > 100) p = 100; printf "%d", p }')
    cu_progress_bar "$pct" "${CU_BAR_WIDTH:-10}" "${_CU_PACE_COLOR:-$CU_GREEN}"
}

# Single-line segment: " | pace: <overshoot>", nothing when not available.
cu_pace_render_inline() {
    cu_pace_load "$@" || return 0
    printf " %s|%s %space:%s %s" \
        "$(cu_color "$CU_DIM")" "$(cu_reset)" \
        "$(cu_color "${CU_COLOR_LABEL:-$CU_DIM}")" "$(cu_reset)" \
        "$(cu_pace_fmt_overshoot)"
}

# Multi-line row: "\npa <bar>  <overshoot>", aligned with the 5h/7d rows.
cu_pace_render_multiline() {
    cu_pace_load "$@" || return 0
    printf "\n%spa%s %s  %s" \
        "$(cu_color "${CU_COLOR_LABEL:-$CU_DIM}")" "$(cu_reset)" \
        "$(cu_pace_bar)" \
        "$(cu_pace_fmt_overshoot)"
}
