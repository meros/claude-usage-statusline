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
    # Calculate ETA to 100% using moving average of positive hourly deltas
    # Args: field (five_hour|seven_day), avg_window (number of recent positive deltas to average)
    local field="${1:-seven_day}" avg_window="${2:-24}"
    local values=()
    local timestamps=()

    # Read enough history to cover the averaging window
    local read_hours=$((avg_window + 1))
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts val
        ts=$(echo "$line" | jq -r '.ts' 2>/dev/null)
        val=$(echo "$line" | jq -r ".$field.util" 2>/dev/null)
        [ -n "$ts" ] && [ -n "$val" ] && timestamps+=("$ts") && values+=("$val")
    done < <(cu_history_read "$read_hours")

    local n=${#values[@]}
    [ "$n" -lt 2 ] && return 1

    # Build ts/val input for awk, then compute moving average of positive deltas
    local result
    result=$(_cu_eta_build_input | \
        awk -v window="$avg_window" '
        {
            ts[NR-1] = $1
            val[NR-1] = $2
            n = NR
        }
        END {
            if (n < 2) exit 1
            delta_count = 0
            for (i = 1; i < n; i++) {
                dt_hours = (ts[i] - ts[i-1]) / 3600
                if (dt_hours <= 0) continue
                delta = (val[i] - val[i-1]) / dt_hours
                if (delta > 0) {
                    deltas[delta_count] = delta
                    delta_count++
                }
            }
            if (delta_count == 0) exit 1

            use_count = (window < delta_count) ? window : delta_count
            start = delta_count - use_count
            sum = 0
            for (i = start; i < delta_count; i++) {
                sum += deltas[i]
            }
            rate = sum / use_count

            if (rate <= 0) exit 1
            remaining = 100 - val[n-1]
            if (remaining <= 0) exit 1
            hours_to_cap = remaining / rate
            secs_to_cap = int(hours_to_cap * 3600)
            printf "%.1f %.1f %d", rate, hours_to_cap, secs_to_cap
        }' 2>/dev/null) || return 1

    local rate hours_to_cap secs_to_cap
    read -r rate hours_to_cap secs_to_cap <<< "$result"

    # Check if before reset
    local reset_at
    reset_at=$(cu_history_read "$read_hours" | tail -1 | jq -r ".$field.resets_at // empty" 2>/dev/null)
    local before_reset=""
    if [ -n "$reset_at" ]; then
        local secs_to_reset
        secs_to_reset=$(cu_secs_until_reset "$reset_at")
        if [ "$secs_to_cap" -lt "$secs_to_reset" ] 2>/dev/null; then
            before_reset="BEFORE RESET"
        fi
    fi

    # Output: space-delimited "rate hours secs before_reset_flag"
    printf "%s %s %s %s\n" "$rate" "$hours_to_cap" "$secs_to_cap" "${before_reset:+1}"
}

_cu_eta_build_input() {
    # Helper: outputs "timestamp value" lines from the values/timestamps arrays
    # These arrays are set by the calling cu_eta_projection function
    local i
    for ((i=0; i<${#timestamps[@]}; i++)); do
        printf "%s %s\n" "${timestamps[$i]}" "${values[$i]}"
    done
}

cu_braille_sparkline() {
    # Compact sparkline using Braille characters — 2 data points per column.
    # Left column uses dots 1,2,3 (⠁⠂⠄), right column uses dots 4,5,6 (⠈⠐⠠).
    # Encodes pairs of values into a single Braille character.
    local values=()
    local max_val="${CU_SPARK_MAX:-100}"

    if [ $# -gt 0 ]; then
        values=("$@")
    else
        while IFS= read -r line; do
            [ -n "$line" ] && values+=("$line")
        done
    fi

    [ ${#values[@]} -eq 0 ] && return

    # Braille dot patterns for 4 levels (0-3) per column
    # Left column (dots 7,2,1 from bottom): 0=⠀ 1=⠄ 2=⠆ 3=⠇
    # Right column (dots 8,5,4 from bottom): 0=⠀ 1=⠠ 2=⠰ 3=⠸
    # Braille base: U+2800, dots are bit flags: d1=0x01 d2=0x02 d3=0x04 d4=0x08 d5=0x10 d6=0x20 d7=0x40 d8=0x80
    # We use dots 1,2,3 for left (bits 0x01,0x02,0x04) and dots 4,5,6 for right (bits 0x08,0x10,0x20)
    local left_bits=(0 1 3 7)    # 0=none, 1=d1, 2=d1+d2, 3=d1+d2+d3
    local right_bits=(0 8 24 56) # 0=none, 1=d4, 2=d4+d5, 3=d4+d5+d6

    local i=0
    local count=${#values[@]}
    while [ "$i" -lt "$count" ]; do
        local lval="${values[$i]}"
        lval="${lval%.*}"; lval="${lval:-0}"
        [ "$lval" -lt 0 ] 2>/dev/null && lval=0
        [ "$lval" -gt "$max_val" ] 2>/dev/null && lval="$max_val"
        local lidx=0
        [ "$max_val" -gt 0 ] && lidx=$(( (lval * 3) / max_val ))
        [ "$lidx" -gt 3 ] && lidx=3

        local rval=0 ridx=0
        if [ $((i + 1)) -lt "$count" ]; then
            rval="${values[$((i + 1))]}"
            rval="${rval%.*}"; rval="${rval:-0}"
            [ "$rval" -lt 0 ] 2>/dev/null && rval=0
            [ "$rval" -gt "$max_val" ] 2>/dev/null && rval="$max_val"
            [ "$max_val" -gt 0 ] && ridx=$(( (rval * 3) / max_val ))
            [ "$ridx" -gt 3 ] && ridx=3
        fi

        local codepoint=$((0x2800 + ${left_bits[$lidx]} + ${right_bits[$ridx]}))
        printf "\\U$(printf '%08x' "$codepoint")"

        i=$((i + 2))
    done
}

cu_sparkline_from_history() {
    local field="${1:-seven_day}" hours="${2:-168}" width="${3:-40}"
    local compact="${4:-}" # "braille" for compact mode
    local values=()
    while IFS= read -r val; do
        [ -n "$val" ] && values+=("$val")
    done < <(cu_history_values "$field" "$hours")

    [ ${#values[@]} -eq 0 ] && return

    if [ "$compact" = "braille" ]; then
        cu_braille_sparkline "${values[@]}"
    else
        CU_OPT_WIDTH="$width" cu_sparkline "${values[@]}"
    fi
}
