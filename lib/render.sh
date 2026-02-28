#!/usr/bin/env bash
# render.sh - Sparkline, progress bar, color-coded output

CU_SPARK_ARRAY=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

cu_sparkline() {
    local values=()
    local max_val="${CU_SPARK_MAX:-100}"

    # Read values from args or stdin
    if [ $# -gt 0 ]; then
        values=("$@")
    else
        while IFS= read -r line; do
            [ -n "$line" ] && values+=("$line")
        done
    fi

    [ ${#values[@]} -eq 0 ] && return

    local width="${CU_OPT_WIDTH:-${#values[@]}}"

    # If more values than width, sample evenly
    local step=1
    local count=${#values[@]}
    if [ "$count" -gt "$width" ]; then
        step=$((count / width))
    fi

    local i=0
    local chars_written=0
    while [ "$i" -lt "$count" ] && [ "$chars_written" -lt "$width" ]; do
        local val="${values[$i]}"
        val="${val%.*}" # truncate to integer
        val="${val:-0}"
        [ "$val" -lt 0 ] 2>/dev/null && val=0
        [ "$val" -gt "$max_val" ] 2>/dev/null && val="$max_val"

        # Map to 0-7 index
        local idx
        if [ "$max_val" -gt 0 ]; then
            idx=$(( (val * 7) / max_val ))
        else
            idx=0
        fi
        [ "$idx" -gt 7 ] && idx=7

        printf '%s' "${CU_SPARK_ARRAY[$idx]}"
        chars_written=$((chars_written + 1))
        i=$((i + step))
    done
}

cu_progress_bar() {
    local pct="${1:-0}" width="${2:-20}"
    pct="${pct%.*}"
    pct="${pct:-0}"
    [ "$pct" -gt 100 ] && pct=100
    [ "$pct" -lt 0 ] && pct=0

    local filled=$(( (pct * width) / 100 ))
    local empty=$((width - filled))

    local color
    color=$(cu_pct_color "$pct")

    local bar=""
    bar+="$(cu_color "$color")"
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="$(cu_color "$CU_DIM")"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="$(cu_reset)"

    echo -n "$bar"
}

cu_fmt_pct() {
    local pct="${1:-0}"
    local int_pct="${pct%.*}"
    int_pct="${int_pct:-0}"
    local color
    color=$(cu_pct_color "$int_pct")
    printf "%s%d%%%s" "$(cu_color "$color")" "$int_pct" "$(cu_reset)"
}

cu_eta_projection() {
    # Calculate ETA to 100% based on history trend
    local field="${1:-seven_day}" hours="${2:-48}"
    local values=()
    local timestamps=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts val
        ts=$(echo "$line" | jq -r '.ts' 2>/dev/null)
        val=$(echo "$line" | jq -r ".$field.util" 2>/dev/null)
        [ -n "$ts" ] && [ -n "$val" ] && timestamps+=("$ts") && values+=("$val")
    done < <(cu_history_read "$hours")

    local n=${#values[@]}
    [ "$n" -lt 2 ] && return 1

    # Simple linear regression: rate of change per hour
    local first_val="${values[0]}"
    local last_val="${values[$((n-1))]}"
    local first_ts="${timestamps[0]}"
    local last_ts="${timestamps[$((n-1))]}"

    local dt=$((last_ts - first_ts))
    [ "$dt" -le 0 ] && return 1

    # Use awk for floating-point math (no bc dependency)
    local result
    result=$(awk -v dt="$dt" -v first="$first_val" -v last="$last_val" '
        BEGIN {
            dt_hours = dt / 3600
            if (dt_hours <= 0) exit 1
            rate = (last - first) / dt_hours
            if (rate <= 0) exit 1
            remaining = 100 - last
            hours_to_cap = remaining / rate
            secs_to_cap = int(hours_to_cap * 3600)
            printf "%.1f %.1f %d", rate, hours_to_cap, secs_to_cap
        }' 2>/dev/null) || return 1

    local rate hours_to_cap secs_to_cap
    read -r rate hours_to_cap secs_to_cap <<< "$result"

    # Check if before reset
    local reset_at
    reset_at=$(cu_history_read "$hours" | tail -1 | jq -r ".$field.resets_at // empty" 2>/dev/null)
    local before_reset=""
    if [ -n "$reset_at" ]; then
        local secs_to_reset
        secs_to_reset=$(cu_secs_until_reset "$reset_at")
        if [ "$secs_to_cap" -lt "$secs_to_reset" ] 2>/dev/null; then
            before_reset="BEFORE RESET"
        fi
    fi

    # Output
    printf "rate=%s eta_hours=%s eta_secs=%s" "$rate" "$hours_to_cap" "$secs_to_cap"
    [ -n "$before_reset" ] && printf " before_reset=1"
    printf "\n"
}

cu_sparkline_from_history() {
    local field="${1:-seven_day}" hours="${2:-168}" width="${3:-40}"
    local values=()
    while IFS= read -r val; do
        [ -n "$val" ] && values+=("$val")
    done < <(cu_history_values "$field" "$hours")

    [ ${#values[@]} -eq 0 ] && return

    CU_OPT_WIDTH="$width" cu_sparkline "${values[@]}"
}
