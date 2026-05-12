#!/usr/bin/env bash
# pace.sh — render the pacing contract written by ~/.claude/hooks/budget-pacing.py
#
# Statusline NEVER depends on pacing being installed. The contract file is the
# only point of coupling. Missing or stale (> CU_PACE_STALE_SECONDS) → render
# nothing, statusline keeps working unchanged.

CU_PACE_CONTRACT_PATH="${CU_PACE_CONTRACT_PATH:-$HOME/.cache/claude-pacing/statusline.json}"
CU_PACE_STALE_SECONDS="${CU_PACE_STALE_SECONDS:-120}"
CU_PACE_ENABLED="${CU_PACE_ENABLED:-1}"
CU_PACE_DENY_THRESHOLD="${CU_PACE_DENY_THRESHOLD:-30}"  # used only for bar scaling

# Loads contract into _CU_PACE_* globals; returns non-zero when not renderable.
cu_pace_load() {
    _CU_PACE_MODE=""
    _CU_PACE_UTIL=""
    _CU_PACE_TARGET=""
    _CU_PACE_THROTTLE_MS=""
    _CU_PACE_OVERSHOOT=""

    [ "$CU_PACE_ENABLED" = "1" ] || return 1
    [ -r "$CU_PACE_CONTRACT_PATH" ] || return 1

    local data
    data=$(cat "$CU_PACE_CONTRACT_PATH" 2>/dev/null) || return 1
    [ -z "$data" ] && return 1

    local schema
    schema=$(echo "$data" | jq -r '.schema // 0' 2>/dev/null)
    [ "$schema" = "1" ] || return 1

    local updated_at age now
    updated_at=$(echo "$data" | jq -r '.updated_at // 0' 2>/dev/null)
    now=$(date +%s)
    age=$(( now - updated_at ))
    [ "$age" -gt "$CU_PACE_STALE_SECONDS" ] && return 1

    _CU_PACE_MODE=$(echo "$data" | jq -r '.mode // empty' 2>/dev/null)
    [ -z "$_CU_PACE_MODE" ] && return 1

    _CU_PACE_UTIL=$(echo "$data" | jq -r '.util // 0' 2>/dev/null)
    _CU_PACE_TARGET=$(echo "$data" | jq -r '.target // 0' 2>/dev/null)
    _CU_PACE_THROTTLE_MS=$(echo "$data" | jq -r '.throttle_ms // 0' 2>/dev/null)
    _CU_PACE_OVERSHOOT=$(awk -v u="$_CU_PACE_UTIL" -v t="$_CU_PACE_TARGET" \
        'BEGIN { printf "%.1f", u - t }')
    return 0
}

_cu_pace_mode_color() {
    case "$1" in
        deny)     echo "$CU_RED" ;;
        throttle) echo "$CU_YELLOW" ;;
        clear)    echo "$CU_GREEN" ;;
        off)      echo "$CU_DIM" ;;
        *)        echo "$CU_DIM" ;;
    esac
}

cu_pace_fmt_overshoot() {
    local color phrase
    color=$(_cu_pace_mode_color "$_CU_PACE_MODE")
    # Plain English:
    #   util above target → "+N% over budget"
    #   util below target → "N% under budget" (room to spare)
    #   within ±1 pp      → "on the curve"
    phrase=$(awk -v v="$_CU_PACE_OVERSHOOT" 'BEGIN {
        a = (v < 0 ? -v : v);
        if (a < 1.0) { printf "on the curve" }
        else if (v >= 0) { printf "+%.0f%% over budget", v }
        else { printf "%.0f%% under budget", a }
    }')
    printf "%s%s%s" "$(cu_color "$color")" "$phrase" "$(cu_reset)"
}

cu_pace_fmt_state() {
    local color
    color=$(_cu_pace_mode_color "$_CU_PACE_MODE")
    case "$_CU_PACE_MODE" in
        deny)
            printf "%sblocking calls%s" "$(cu_color "$color")" "$(cu_reset)"
            ;;
        throttle)
            local sec
            sec=$(awk -v ms="$_CU_PACE_THROTTLE_MS" \
                'BEGIN { v = ms/1000; printf (v < 10 ? "%.1f" : "%.0f"), v }')
            printf "%s+%ss per call%s" "$(cu_color "$color")" "$sec" "$(cu_reset)"
            ;;
        clear)
            printf "%sno throttle%s" "$(cu_color "$color")" "$(cu_reset)"
            ;;
        off)
            printf "%spacing off%s" "$(cu_color "$color")" "$(cu_reset)"
            ;;
        *)
            return 0
            ;;
    esac
}

# Bar: overshoot scaled against the deny threshold. Mirrors cu_progress_bar's
# █/░ characters and dim background so the row visually matches 5h / 7d.
cu_pace_bar() {
    local width="${CU_BAR_WIDTH:-10}"
    local deny="$CU_PACE_DENY_THRESHOLD"
    local pct
    pct=$(awk -v o="$_CU_PACE_OVERSHOOT" -v d="$deny" \
        'BEGIN { v = (o < 0 ? 0 : o); p = (v * 100) / d; if (p > 100) p = 100; printf "%d", p }')

    local color
    color=$(_cu_pace_mode_color "$_CU_PACE_MODE")
    # In `off` mode, dim the entire bar so it doesn't draw the eye
    [ "$_CU_PACE_MODE" = "off" ] && color="$CU_DIM"

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

# Single-line: returns " | pace: +Npp <state>", empty if not renderable.
cu_pace_render_inline() {
    cu_pace_load || return 0
    printf " %s|%s %space:%s %s %s" \
        "$(cu_color "$CU_DIM")" "$(cu_reset)" \
        "$(cu_color "$CU_COLOR_LABEL")" "$(cu_reset)" \
        "$(cu_pace_fmt_overshoot)" \
        "$(cu_pace_fmt_state)"
}

# Multi-line: prints "\npa <bar> <overshoot> <state>", aligned with 5h/7d rows.
cu_pace_render_multiline() {
    cu_pace_load || return 0
    printf "\n%spa%s %s  %s  %s" \
        "$(cu_color "$CU_COLOR_LABEL")" "$(cu_reset)" \
        "$(cu_pace_bar)" \
        "$(cu_pace_fmt_overshoot)" \
        "$(cu_pace_fmt_state)"
}
