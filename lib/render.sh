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

cu_fmt_rate_per_window() {
    # Convert %/hour rate to %/avg_window string
    # Args: rate_per_hour, avg_window_hours
    local rate="$1" window_hours="${2:-24}"
    local rate_per_window label
    rate_per_window=$(awk -v r="$rate" -v w="$window_hours" 'BEGIN { printf "%.0f", r * w }')
    if [ "$window_hours" -ge 24 ] && [ $((window_hours % 24)) -eq 0 ]; then
        label="/$(( window_hours / 24 ))d"
    else
        label="/${window_hours}h"
    fi
    printf "%s%%%s" "$rate_per_window" "$label"
}

cu_eta_projection() {
    # Calculate ETA to 100% using moving average of positive hourly deltas
    # Args: field (five_hour|seven_day), avg_window (number of recent positive deltas to average), tier (short|long)
    local field="${1:-seven_day}" avg_window="${2:-24}" tier="${3:-}"
    local values=()
    local timestamps=()

    # Prefer short tier (fine-grained 5-min data) for accurate rate calculation
    # Fall back to long tier if short tier lacks sufficient data
    local auto_tier=0
    if [ -z "$tier" ]; then
        tier="short"
        auto_tier=1
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
    if [ "$n" -lt 2 ]; then
        # Fall back to long tier if short tier lacks data
        if [ "$auto_tier" = "1" ] && [ "$tier" = "short" ]; then
            cu_eta_projection "$field" "$avg_window" "long"
            return $?
        fi
        return 1
    fi

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

            # Wall-clock rate: total change over total time for the window
            # This includes idle periods, giving a realistic calendar ETA
            total_hours = (ts[n-1] - ts[0]) / 3600
            if (total_hours <= 0) exit 1

            # Use only the last "window" hours of data
            win_start = 0
            if (total_hours > window) {
                cutoff = ts[n-1] - window * 3600
                for (i = 0; i < n; i++) {
                    if (ts[i] >= cutoff) { win_start = i; break }
                }
            }

            win_hours = (ts[n-1] - ts[win_start]) / 3600
            if (win_hours <= 0) exit 1
            win_change = val[n-1] - val[win_start]
            if (win_change <= 0) exit 1
            rate = win_change / win_hours

            if (rate <= 0) exit 1
            remaining = 100 - val[n-1]
            if (remaining <= 0) exit 1
            hours_to_cap = remaining / rate
            secs_to_cap = int(hours_to_cap * 3600)
            printf "%.1f %.1f %d", rate, hours_to_cap, secs_to_cap
        }' 2>/dev/null)
    if [ -z "$result" ]; then
        # Fall back to long tier if short tier rate calculation failed
        if [ "$auto_tier" = "1" ] && [ "$tier" = "short" ]; then
            cu_eta_projection "$field" "$avg_window" "long"
            return $?
        fi
        return 1
    fi

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

_cu_interpolate() {
    # Linear interpolation at timestamp $1 using rec_ts/rec_val arrays from caller
    # Does NOT interpolate across reset boundaries (value drops > 5%)
    local t="$1"
    local n=${#rec_ts[@]}
    [ "$n" -eq 0 ] && return

    # Before first point
    [ "$t" -le "${rec_ts[0]}" ] && echo "${rec_val[0]}" && return
    # After last point
    [ "$t" -ge "${rec_ts[$((n-1))]}" ] && echo "${rec_val[$((n-1))]}" && return

    # Find surrounding points
    local j
    for ((j=1; j<n; j++)); do
        if [ "$t" -le "${rec_ts[$j]}" ]; then
            local t0="${rec_ts[$((j-1))]}" t1="${rec_ts[$j]}"
            local v0="${rec_val[$((j-1))]}" v1="${rec_val[$j]}"
            if [ "$t0" -eq "$t1" ]; then
                echo "$v0"
            else
                # Check for reset between these points (value drop > 5%)
                local is_reset
                is_reset=$(awk "BEGIN { print ($v1 - $v0 < -5) ? 1 : 0 }")
                if [ "$is_reset" = "1" ]; then
                    # Don't interpolate across reset — snap to nearest side
                    local mid=$(( (t0 + t1) / 2 ))
                    if [ "$t" -le "$mid" ]; then
                        echo "$v0"
                    else
                        echo "$v1"
                    fi
                else
                    awk "BEGIN { printf \"%.1f\", $v0 + ($v1-$v0) * ($t-$t0) / ($t1-$t0) }"
                fi
            fi
            return
        fi
    done
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

    # Read all records with timestamps, values, and resets_at
    local -a rec_ts=() rec_val=() rec_reset=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ts val ra
        ts=$(echo "$line" | jq -r '.ts' 2>/dev/null)
        val=$(echo "$line" | jq -r ".$field.util" 2>/dev/null)
        ra=$(echo "$line" | jq -r ".$field.resets_at // empty" 2>/dev/null)
        [ -z "$ts" ] || [ -z "$val" ] || [ "$val" = "null" ] && continue
        rec_ts+=("$ts")
        rec_val+=("$val")
        rec_reset+=("$ra")
    done < <(cu_history_read "$tier" "$hours")

    [ ${#rec_ts[@]} -eq 0 ] && return

    # Detect reset times from resets_at field changes
    # A reset occurred when the resets_at epoch jumps forward (new window started)
    local -a reset_slots=()
    local prev_reset_epoch=""
    for ((i=0; i<${#rec_ts[@]}; i++)); do
        [ -z "${rec_reset[$i]}" ] && continue
        local reset_epoch
        reset_epoch=$(date -d "${rec_reset[$i]}" +%s 2>/dev/null || \
                      date -j -f "%Y-%m-%dT%H:%M:%S" "${rec_reset[$i]%%.*}" +%s 2>/dev/null) || continue
        if [ -n "$prev_reset_epoch" ] && [ "$reset_epoch" -gt "$((prev_reset_epoch + 300))" ]; then
            # Reset happened at the old resets_at time — place marker there
            local rslot=$(( (prev_reset_epoch - window_start) / slot_secs ))
            [ "$rslot" -ge 0 ] && [ "$rslot" -lt "$data_points" ] && reset_slots+=("$rslot")
        fi
        prev_reset_epoch="$reset_epoch"
    done

    # Interpolate a value at each slot boundary, then compute per-slot deltas
    # This distributes change evenly across gaps instead of spiking
    local -a deltas=()
    for ((i=0; i<data_points; i++)); do
        local slot_start=$((window_start + i * slot_secs))
        local slot_end=$((slot_start + slot_secs))
        # Interpolate values at slot_start and slot_end
        local v_start v_end
        v_start=$(_cu_interpolate "$slot_start")
        v_end=$(_cu_interpolate "$slot_end")
        if [ -n "$v_start" ] && [ -n "$v_end" ]; then
            local d
            d=$(awk "BEGIN { d=int($v_end - $v_start); print (d<0) ? 0 : d }")
            deltas+=("$d")
        else
            deltas+=(0)
        fi
    done

    [ ${#deltas[@]} -eq 0 ] && return

    if [ "$compact" = "braille" ] && [ ${#reset_slots[@]} -gt 0 ]; then
        # Render braille with reset markers: replace chars at reset positions with ↻
        _cu_braille_with_resets
    elif [ "$compact" = "braille" ]; then
        cu_braille_sparkline "${deltas[@]}"
    else
        CU_OPT_WIDTH="$width" cu_sparkline "${deltas[@]}"
    fi
}

_cu_braille_with_resets() {
    # Render braille sparkline, inserting ↻ at positions where resets occurred
    # Uses deltas[] and reset_slots[] from calling cu_sparkline_from_history

    # Build a set of reset slot indices for O(1) lookup
    local -A reset_set=()
    local rs
    for rs in "${reset_slots[@]}"; do
        reset_set[$rs]=1
    done

    # Render braille chars one pair at a time, substituting ↻ at reset positions
    local count=${#deltas[@]}
    local max_val="${CU_SPARK_MAX:-100}"

    # Auto-scale
    local data_max=0 j
    for ((j=0; j<count; j++)); do
        local v="${deltas[$j]%.*}"; v="${v:-0}"
        [ "$v" -gt "$data_max" ] 2>/dev/null && data_max="$v"
    done
    local scale_max="$data_max"
    [ "$scale_max" -lt 1 ] 2>/dev/null && scale_max=1

    local left_bits=(0 4 6 7)
    local right_bits=(0 32 48 56)

    local delta_idx=0
    while [ "$delta_idx" -lt "$count" ]; do
        local has_reset=""
        [ "${reset_set[$delta_idx]:-}" = "1" ] && has_reset=1
        [ $((delta_idx + 1)) -lt "$count" ] && [ "${reset_set[$((delta_idx+1))]:-}" = "1" ] && has_reset=1

        if [ "$has_reset" = "1" ]; then
            printf '↻'
        else
            local lval="${deltas[$delta_idx]%.*}"; lval="${lval:-0}"
            [ "$lval" -lt 0 ] 2>/dev/null && lval=0
            [ "$lval" -gt "$max_val" ] 2>/dev/null && lval="$max_val"
            local lidx=$(( (lval * 3) / scale_max ))
            [ "$lidx" -gt 3 ] && lidx=3

            local rval=0 ridx=0
            if [ $((delta_idx + 1)) -lt "$count" ]; then
                rval="${deltas[$((delta_idx + 1))]%.*}"; rval="${rval:-0}"
                [ "$rval" -lt 0 ] 2>/dev/null && rval=0
                [ "$rval" -gt "$max_val" ] 2>/dev/null && rval="$max_val"
                ridx=$(( (rval * 3) / scale_max ))
                [ "$ridx" -gt 3 ] && ridx=3
            fi

            local codepoint=$((0x2800 + ${left_bits[$lidx]} + ${right_bits[$ridx]}))
            printf "\\U$(printf '%08x' "$codepoint")"
        fi
        delta_idx=$((delta_idx + 2))
    done
}
