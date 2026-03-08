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
    # Calculate ETA to 100% using net change over a wall-clock window
    # Args: field (five_hour|seven_day), avg_window (hours), tier (short|long)
    local field="${1:-seven_day}" avg_window="${2:-24}" tier="${3:-}"

    # Prefer short tier (fine-grained 5-min data) for accurate rate calculation
    # Fall back to long tier if short tier lacks sufficient data
    local auto_tier=0
    if [ -z "$tier" ]; then
        tier="short"
        auto_tier=1
    fi

    # Read extra history to bridge polling gaps (e.g. laptop sleep, weekends)
    local read_hours=$((avg_window * 3))
    local tsv_data
    tsv_data=$(cu_history_read "$tier" "$read_hours" | \
        jq -r --arg f "$field" '
            select(.[$f] != null and .[$f].util != null) |
            [.ts, .[$f].util, (.[$f].resets_at // "")] | @tsv' 2>/dev/null)

    # Compute rate via net change over the averaging window.
    #
    # Key design decisions:
    #   - Net change (end − start) instead of sum-of-positive-deltas, so API
    #     value jitter doesn't inflate the rate.
    #   - Reset detection: if a drop > 30 points occurs in the data, only
    #     post-reset usage counts (pre-reset consumption is irrelevant to
    #     current time-to-cap).
    #   - Gaps (laptop sleep, weekends): we find the last known value AT OR
    #     BEFORE the window boundary — no interpolation across gaps, because
    #     utilization doesn't change while the machine is off.
    #   - The denominator is always wall-clock hours (window size or time
    #     since reset), so %/1d means "consumption per calendar day" including
    #     idle time.
    #   - Minimum data requirement: need at least 2 distinct values within the
    #     effective window (otherwise can't compute a rate).
    local result
    result=$(printf '%s\n' "$tsv_data" | awk -F'\t' -v window="$avg_window" '
        BEGIN { n = 0 }
        NF >= 2 {
            ts[n] = $1 + 0
            val[n] = $2 + 0
            n++
        }
        END {
            if (n < 2) exit 1

            t_end = ts[n-1]
            t_start = t_end - window * 3600

            # --- Reset detection (scan ALL loaded data) ---
            # Find the last reset (drop > 30 points). If a reset occurred,
            # only post-reset data matters for predicting time-to-cap.
            last_reset = -1
            for (i = 1; i < n; i++) {
                if ((val[i] - val[i-1]) < -30) last_reset = i
            }

            # --- Determine start value and effective window ---
            # Two cases:
            #   1. Reset WITHIN the window: measure from reset point, denominator
            #      is time-since-reset (can be short — that is all we have).
            #   2. Reset BEFORE the window (or no reset): use the last known
            #      value at or before the window boundary. Denominator is the
            #      full window. No interpolation across gaps (value is flat
            #      when not polling).
            has_recent_reset = 0
            if (last_reset >= 0 && ts[last_reset] >= t_start) {
                # Reset inside the window
                start_val = val[last_reset]
                effective_start = ts[last_reset]
                has_recent_reset = 1
            } else {
                # No reset, or reset was before the window.
                # Find last data point at or before t_start (post-reset if applicable).
                first_valid = (last_reset >= 0) ? last_reset : 0
                if (t_start <= ts[first_valid]) {
                    start_val = val[first_valid]
                    effective_start = ts[first_valid]
                } else {
                    boundary = first_valid
                    for (i = first_valid; i < n; i++) {
                        if (ts[i] <= t_start) boundary = i
                        else break
                    }
                    start_val = val[boundary]
                    effective_start = t_start  # wall-clock window start
                }
            }

            net_change = val[n-1] - start_val
            if (net_change <= 0) exit 1

            win_hours = (t_end - effective_start) / 3600
            if (win_hours <= 0) exit 1

            # Minimum data span: need at least 25% of requested window
            # covered, otherwise the projection is unreliable.
            # Exception: reset within the window — the post-reset span IS all
            # the relevant data, we cannot look further back.
            if (!has_recent_reset && win_hours < window * 0.25) exit 1

            rate = net_change / win_hours

            remaining = 100 - val[n-1]
            if (remaining <= 0) exit 1
            hours_to_cap = remaining / rate
            secs_to_cap = int(hours_to_cap * 3600)
            printf "%.1f %.1f %d", rate, hours_to_cap, secs_to_cap
        }' 2>/dev/null)
    if [ -z "$result" ]; then
        if [ "$auto_tier" = "1" ] && [ "$tier" = "short" ]; then
            cu_eta_projection "$field" "$avg_window" "long"
            return $?
        fi
        return 1
    fi

    local rate hours_to_cap secs_to_cap
    read -r rate hours_to_cap secs_to_cap <<< "$result"

    # Extract resets_at from last TSV line (no extra jq call)
    local reset_at
    reset_at=$(printf '%s\n' "$tsv_data" | tail -1 | cut -f3)
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

cu_braille_sparkline() {
    # Compact sparkline using 8-dot Braille characters — 2 data points per column.
    # Left column uses dots 7,3,2,1 (bottom-up), right column uses dots 8,6,5,4.
    # Encodes pairs of values into a single Braille character (5 levels: 0-4).
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

    # Braille 8-dot layout (U+2800 base, bit flags per dot):
    #   d1=0x01 d4=0x08
    #   d2=0x02 d5=0x10
    #   d3=0x04 d6=0x20
    #   d7=0x40 d8=0x80
    # Fill bottom-up: left=d7,d3,d2,d1  right=d8,d6,d5,d4
    local left_bits=(0 64 68 70 71)       # 0-4: none, d7, d7+d3, d7+d3+d2, d7+d3+d2+d1
    local right_bits=(0 128 160 176 184)  # 0-4: none, d8, d8+d6, d8+d6+d5, d8+d6+d5+d4

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
        local lidx=$(( (lval * 4) / scale_max ))
        [ "$lidx" -gt 4 ] && lidx=4

        local rval=0 ridx=0
        if [ $((i + 1)) -lt "$count" ]; then
            rval="${values[$((i + 1))]}"
            rval="${rval%.*}"; rval="${rval:-0}"
            [ "$rval" -lt 0 ] 2>/dev/null && rval=0
            [ "$rval" -gt "$max_val" ] 2>/dev/null && rval="$max_val"
            ridx=$(( (rval * 4) / scale_max ))
            [ "$ridx" -gt 4 ] && ridx=4
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

    local now
    now=$(cu_now)
    local window_start=$((now - hours * 3600))
    local slot_secs=$(( (hours * 3600) / data_points ))

    # Single pipeline: jq extracts TSV (ts, val, resets_at_epoch), awk does
    # interpolation, delta computation, and reset detection in one pass
    local awk_output
    awk_output=$(cu_history_read "$tier" "$hours" | \
        jq -r --arg f "$field" '
            select(.[$f] != null and .[$f].util != null) |
            ((.[$f].resets_at // "") | if . == "" then 0
             else (sub("[.+Z].*$"; "Z") | fromdateiso8601) // 0 end) as $ra_epoch |
            [.ts, .[$f].util, $ra_epoch] | @tsv' 2>/dev/null | \
        awk -F'\t' -v win_start="$window_start" -v slot_secs="$slot_secs" -v dp="$data_points" '
        BEGIN { n = 0 }
        function interp(t,    j, t0, t1, v0, v1, mid) {
            if (n == 0) return -1
            if (t <= ts[0]) return val[0]
            if (t >= ts[n-1]) return val[n-1]
            for (j = 1; j < n; j++) {
                if (t <= ts[j]) {
                    t0 = ts[j-1]; t1 = ts[j]
                    v0 = val[j-1]; v1 = val[j]
                    if (t0 == t1) return v0
                    # Reset boundary: value drop > 5% — snap to nearest side
                    if (v1 - v0 < -5) {
                        mid = int((t0 + t1) / 2)
                        return (t <= mid) ? v0 : v1
                    }
                    return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
                }
            }
            return val[n-1]
        }
        {
            ts[n] = $1 + 0
            val[n] = $2 + 0
            ra[n] = $3 + 0
            n++
        }
        END {
            if (n == 0) exit 1

            # Detect reset slots from resets_at epoch jumps (>300s forward)
            prev_ra = 0
            rc = 0
            for (i = 0; i < n; i++) {
                if (ra[i] == 0) continue
                if (prev_ra > 0 && ra[i] > prev_ra + 300) {
                    rslot = int((prev_ra - win_start) / slot_secs)
                    if (rslot >= 0 && rslot < dp) resets[rc++] = rslot
                }
                prev_ra = ra[i]
            }

            # Interpolate at slot boundaries and compute per-slot deltas
            for (i = 0; i < dp; i++) {
                s0 = win_start + i * slot_secs
                s1 = s0 + slot_secs
                v_s = interp(s0)
                v_e = interp(s1)
                if (v_s >= 0 && v_e >= 0) {
                    d = int(v_e - v_s)
                    deltas[i] = (d < 0) ? 0 : d
                } else {
                    deltas[i] = 0
                }
            }

            # Line 1: space-separated deltas
            for (i = 0; i < dp; i++) {
                if (i > 0) printf " "
                printf "%d", deltas[i]
            }
            printf "\n"
            # Line 2: space-separated reset slot indices
            for (i = 0; i < rc; i++) {
                if (i > 0) printf " "
                printf "%d", resets[i]
            }
            printf "\n"
        }')

    [ -z "$awk_output" ] && return

    # Parse deltas and reset slots from awk output
    local deltas_line reset_line
    deltas_line=$(printf '%s\n' "$awk_output" | head -1)
    reset_line=$(printf '%s\n' "$awk_output" | sed -n '2p')

    local -a deltas=()
    read -ra deltas <<< "$deltas_line"
    [ ${#deltas[@]} -eq 0 ] && return

    local -a reset_slots=()
    [ -n "$reset_line" ] && read -ra reset_slots <<< "$reset_line"

    if [ "$compact" = "braille" ] && [ ${#reset_slots[@]} -gt 0 ]; then
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

    local left_bits=(0 64 68 70 71)
    local right_bits=(0 128 160 176 184)

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
            local lidx=$(( (lval * 4) / scale_max ))
            [ "$lidx" -gt 4 ] && lidx=4

            local rval=0 ridx=0
            if [ $((delta_idx + 1)) -lt "$count" ]; then
                rval="${deltas[$((delta_idx + 1))]%.*}"; rval="${rval:-0}"
                [ "$rval" -lt 0 ] 2>/dev/null && rval=0
                [ "$rval" -gt "$max_val" ] 2>/dev/null && rval="$max_val"
                ridx=$(( (rval * 4) / scale_max ))
                [ "$ridx" -gt 4 ] && ridx=4
            fi

            local codepoint=$((0x2800 + ${left_bits[$lidx]} + ${right_bits[$ridx]}))
            printf "\\U$(printf '%08x' "$codepoint")"
        fi
        delta_idx=$((delta_idx + 2))
    done
}
