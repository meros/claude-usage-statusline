#!/usr/bin/env bash
# pace.sh — render target-curve budget pacing metric
#
# Shows whether 7-day usage is on, over, or under the work-hours budget curve.
# Pure metric: no throttling, no sleeping, no blocking.

CU_PACE_CONTRACT_PATH="${CU_PACE_CONTRACT_PATH:-$HOME/.cache/claude-pacing/statusline.json}"
CU_PACE_STALE_SECONDS="${CU_PACE_STALE_SECONDS:-120}"
CU_PACE_ENABLED="${CU_PACE_ENABLED:-1}"
CU_PACE_DENY_THRESHOLD="${CU_PACE_DENY_THRESHOLD:-30}"  # overshoot pp at which bar is full

# Loads/computes pacing metric into _CU_PACE_* globals; returns non-zero when not renderable.
cu_pace_load() {
    _CU_PACE_UTIL=""
    _CU_PACE_TARGET=""
    _CU_PACE_OVERSHOOT=""
    _CU_PACE_COLOR=""

    [ "${CU_PACE_ENABLED:-1}" = "1" ] || return 1

    # Do not render pacing metric when limits are suppressed
    if declare -F cu_limits_disabled >/dev/null && cu_limits_disabled; then
        return 1
    fi

    local util="${1:-}" reset_val="${2:-}"

    # If arguments not provided, attempt to read from cache
    if [ -z "$util" ] || [ -z "$reset_val" ]; then
        if declare -F cu_read_cache >/dev/null; then
            local cache_data
            cache_data=$(cu_read_cache 2>/dev/null)
            if [ -n "$cache_data" ]; then
                util=$(cu_get_seven_day_pct "$cache_data" 2>/dev/null)
                reset_val=$(cu_get_seven_day_reset "$cache_data" 2>/dev/null)
            fi
        fi
    fi

    # Fallback to contract file if arguments and cache are unavailable
    if [ -z "$util" ] || [ -z "$reset_val" ]; then
        if [ -r "$CU_PACE_CONTRACT_PATH" ]; then
            local data
            data=$(cat "$CU_PACE_CONTRACT_PATH" 2>/dev/null)
            if [ -n "$data" ]; then
                local updated_at now age
                updated_at=$(echo "$data" | jq -r '.updated_at // 0' 2>/dev/null)
                now=$(cu_now)
                age=$(( now - updated_at ))
                if [ "$age" -le "${CU_PACE_STALE_SECONDS:-120}" ]; then
                    _CU_PACE_UTIL=$(echo "$data" | jq -r '.util // 0' 2>/dev/null)
                    _CU_PACE_TARGET=$(echo "$data" | jq -r '.target // 0' 2>/dev/null)
                    _CU_PACE_OVERSHOOT=$(awk -v u="$_CU_PACE_UTIL" -v t="$_CU_PACE_TARGET" \
                        'BEGIN { printf "%.1f", u - t }')
                fi
            fi
        fi
    else
        # Compute directly from 7-day reset and current time
        local now reset_epoch
        now=$(cu_now)
        if [[ "$reset_val" =~ ^[0-9]+$ ]]; then
            reset_epoch="$reset_val"
        else
            reset_epoch=$(date -d "$reset_val" +%s 2>/dev/null)
        fi
        [ -n "$reset_epoch" ] || return 1

        local target
        target=$(jq -n --argjson now "$now" --argjson reset "$reset_epoch" '
            def work_hours($now; $reset):
              if $reset <= $now then 0
              else
                [
                  range($now; $reset; 3600) |
                  localtime |
                  select(.[6] >= 1 and .[6] <= 5 and .[3] >= 7 and .[3] < 16)
                ] | length
              end;

            work_hours($now; $reset) as $wh |
            ([0, (1 - $wh / 45)] | max | [1, .] | min * 100) | round
        ' 2>/dev/null)
        [ -n "$target" ] || return 1

        _CU_PACE_UTIL="$util"
        _CU_PACE_TARGET="$target"
        _CU_PACE_OVERSHOOT=$(awk -v u="$_CU_PACE_UTIL" -v t="$_CU_PACE_TARGET" \
            'BEGIN { printf "%.1f", u - t }')
    fi

    [ -n "$_CU_PACE_OVERSHOOT" ] || return 1

    # Color based on curve position:
    # overshoot <= 0: green (on or under curve)
    # overshoot <= 10: yellow (mild overshoot)
    # overshoot > 10: red (significant overshoot)
    _CU_PACE_COLOR=$(awk -v o="$_CU_PACE_OVERSHOOT" \
        -v g="$CU_GREEN" -v y="$CU_YELLOW" -v r="$CU_RED" '
        BEGIN {
            if (o <= 0) print g
            else if (o <= 10) print y
            else print r
        }')
    return 0
}

cu_pace_fmt_overshoot() {
    local color="${_CU_PACE_COLOR:-$CU_GREEN}" phrase
    # Signed percent delta vs target:
    #   util above target → "+N% over"
    #   util below target → "-N% under"
    #   within ±1 pp      → "±0% on curve"
    phrase=$(awk -v v="$_CU_PACE_OVERSHOOT" 'BEGIN {
        a = (v < 0 ? -v : v);
        if (a < 1.0) { printf "±0%% on curve" }
        else if (v >= 0) { printf "+%.0f%% over", v }
        else { printf "-%.0f%% under", a }
    }')
    printf "%s%s%s" "$(cu_color "$color")" "$phrase" "$(cu_reset)"
}

# Bar: overshoot scaled against the threshold (default 30pp). Mirrors cu_progress_bar's
# █/░ characters and dim background so the row visually matches 5h / 7d.
cu_pace_bar() {
    local width="${CU_BAR_WIDTH:-10}"
    local deny="${CU_PACE_DENY_THRESHOLD:-30}"
    local pct
    pct=$(awk -v o="$_CU_PACE_OVERSHOOT" -v d="$deny" \
        'BEGIN { v = (o < 0 ? 0 : o); p = (v * 100) / d; if (p > 100) p = 100; printf "%d", p }')

    local color="${_CU_PACE_COLOR:-$CU_GREEN}"
    local filled=$(( (pct * width) / 100 ))
    local empty=$(( width - filled ))

    local bar i
    bar+="$(cu_color "$color")"
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    bar+="$(cu_color "$CU_DIM")"
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    bar+="$(cu_reset)"
    printf "%s" "$bar"
}

# Single-line: returns " | pace: <overshoot>", empty if not renderable.
cu_pace_render_inline() {
    cu_pace_load "$@" || return 0
    printf " %s|%s %space:%s %s" \
        "$(cu_color "$CU_DIM")" "$(cu_reset)" \
        "$(cu_color "${CU_COLOR_LABEL:-$CU_DIM}")" "$(cu_reset)" \
        "$(cu_pace_fmt_overshoot)"
}

# Multi-line: prints "\npa <bar>  <overshoot>", aligned with 5h/7d rows.
cu_pace_render_multiline() {
    cu_pace_load "$@" || return 0
    printf "\n%spa%s %s  %s" \
        "$(cu_color "${CU_COLOR_LABEL:-$CU_DIM}")" "$(cu_reset)" \
        "$(cu_pace_bar)" \
        "$(cu_pace_fmt_overshoot)"
}
