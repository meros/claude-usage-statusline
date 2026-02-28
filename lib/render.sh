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

    # Auto-scale: find actual max and scale to it (floor stays at 0)
    # This makes low-range data (e.g. 5-15%) show meaningful variation
    local data_max=0
    local j=0
    while [ "$j" -lt "$count" ]; do
        local v="${values[$j]}"
        v="${v%.*}"; v="${v:-0}"
        [ "$v" -gt "$data_max" ] 2>/dev/null && data_max="$v"
        j=$((j + step))
    done
    # Use data max for scaling, but at least 1 to avoid division by zero
    local scale_max="$data_max"
    [ "$scale_max" -lt 1 ] 2>/dev/null && scale_max=1

    local i=0
    local chars_written=0
    while [ "$i" -lt "$count" ] && [ "$chars_written" -lt "$width" ]; do
        local val="${values[$i]}"
        val="${val%.*}" # truncate to integer
        val="${val:-0}"
        [ "$val" -lt 0 ] 2>/dev/null && val=0
        [ "$val" -gt "$max_val" ] 2>/dev/null && val="$max_val"

        # Map to 0-7 index, scaled to actual data max
        local idx
        idx=$(( (val * 7) / scale_max ))
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
    # Args: field (five_hour|seven_day), avg_window (number of recent positive deltas to average), tier (short|long)
    local field="${1:-seven_day}" avg_window="${2:-24}" tier="${3:-}"
    local values=()
    local timestamps=()

    # Default tier based on field
    if [ -z "$tier" ]; then
        case "$field" in
            five_hour) tier="short" ;;
            *)         tier="long" ;;
        esac
    fi

    # Read enough history to cover the averaging window
    local read_hours=$((avg_window + 1))
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts val
        ts=$(echo "$line" | jq -r '.ts' 2>/dev/null)
        val=$(echo "$line" | jq -r ".$field.util" 2>/dev/null)
        [ -n "$ts" ] && [ -n "$val" ] && timestamps+=("$ts") && values+=("$val")
    done < <(cu_history_read "$tier" "$read_hours")

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
    reset_at=$(cu_history_read "$tier" "$read_hours" | tail -1 | jq -r ".$field.resets_at // empty" 2>/dev/null)
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
    # Fill from bottom up: d3(0x04) is bottom-left, d6(0x20) is bottom-right
    local left_bits=(0 4 6 7)     # 0=none, 1=d3, 2=d2+d3, 3=d1+d2+d3
    local right_bits=(0 32 48 56) # 0=none, 1=d6, 2=d5+d6, 3=d4+d5+d6

    # Auto-scale: find actual max (floor stays at 0)
    local data_max=0
    local j
    for ((j=0; j<${#values[@]}; j++)); do
        local v="${values[$j]}"
        v="${v%.*}"; v="${v:-0}"
        [ "$v" -gt "$data_max" ] 2>/dev/null && data_max="$v"
    done
    local scale_max="$data_max"
    [ "$scale_max" -lt 1 ] 2>/dev/null && scale_max=1

    local i=0
    local count=${#values[@]}
    while [ "$i" -lt "$count" ]; do
        local lval="${values[$i]}"
        lval="${lval%.*}"; lval="${lval:-0}"
        [ "$lval" -lt 0 ] 2>/dev/null && lval=0
        [ "$lval" -gt "$max_val" ] 2>/dev/null && lval="$max_val"
        local lidx=$(( (lval * 3) / scale_max ))
        [ "$lidx" -gt 3 ] && lidx=3

        local rval=0 ridx=0
        if [ $((i + 1)) -lt "$count" ]; then
            rval="${values[$((i + 1))]}"
            rval="${rval%.*}"; rval="${rval:-0}"
            [ "$rval" -lt 0 ] 2>/dev/null && rval=0
            [ "$rval" -gt "$max_val" ] 2>/dev/null && rval="$max_val"
            ridx=$(( (rval * 3) / scale_max ))
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
    local tier="${5:-}"

    # Default tier based on field
    if [ -z "$tier" ]; then
        case "$field" in
            five_hour) tier="short" ;;
            *)         tier="long" ;;
        esac
    fi

    # For braille mode, we need 2x data points (2 values per char)
    local data_points="$width"
    [ "$compact" = "braille" ] && data_points=$((width * 2))

    # Read timestamped records and bucket into fixed time slots
    # Each slot covers (hours*3600/data_points) seconds
    local now
    now=$(cu_now)
    local window_start=$((now - hours * 3600))
    local slot_secs=$(( (hours * 3600) / data_points ))

    # Initialize buckets: track last known value per slot for delta computation
    local -a bucket_vals=()
    local i
    for ((i=0; i<data_points; i++)); do
        bucket_vals[$i]=""
    done

    # Read all records with timestamps and values
    local -a rec_ts=() rec_val=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts val
        ts=$(echo "$line" | jq -r '.ts' 2>/dev/null)
        val=$(echo "$line" | jq -r ".$field.util" 2>/dev/null)
        [ -z "$ts" ] || [ -z "$val" ] || [ "$val" = "null" ] && continue
        rec_ts+=("$ts")
        rec_val+=("$val")
    done < <(cu_history_read "$tier" "$hours")

    [ ${#rec_ts[@]} -eq 0 ] && return

    # Assign each record to a time slot
    for ((i=0; i<${#rec_ts[@]}; i++)); do
        local slot=$(( (rec_ts[$i] - window_start) / slot_secs ))
        [ "$slot" -lt 0 ] && slot=0
        [ "$slot" -ge "$data_points" ] && slot=$((data_points - 1))
        bucket_vals[$slot]="${rec_val[$i]}"
    done

    # Compute deltas between consecutive slots that have data
    # For empty slots, output 0 (no activity in that period)
    local -a deltas=()
    local prev_val=""
    for ((i=0; i<data_points; i++)); do
        if [ -n "${bucket_vals[$i]}" ]; then
            if [ -n "$prev_val" ]; then
                local cur="${bucket_vals[$i]%.*}" prv="${prev_val%.*}"
                cur="${cur:-0}"; prv="${prv:-0}"
                local d=$((cur - prv))
                [ "$d" -lt 0 ] && d=0
                deltas+=("$d")
            else
                deltas+=(0)
            fi
            prev_val="${bucket_vals[$i]}"
        else
            deltas+=(0)
        fi
    done

    [ ${#deltas[@]} -eq 0 ] && return

    if [ "$compact" = "braille" ]; then
        cu_braille_sparkline "${deltas[@]}"
    else
        CU_OPT_WIDTH="$width" cu_sparkline "${deltas[@]}"
    fi
}
