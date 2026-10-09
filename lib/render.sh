#!/usr/bin/env bash
# render.sh - Sparklines, progress bars and formatted values

CU_SPARK_BLOCKS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# Braille 8-dot cell (U+2800 + bit flags). Each cell shows two values side by
# side, 0-4 dots high, filled bottom-up:
#   left column  d7,d3,d2,d1 = 0x40,0x04,0x02,0x01
#   right column d8,d6,d5,d4 = 0x80,0x20,0x10,0x08
_CU_BRAILLE_LEFT=(0 64 68 70 71)
_CU_BRAILLE_RIGHT=(0 128 160 176 184)

# Print braille cell U+2800 + BITS as raw UTF-8 bytes (E2, A0 + bits/64,
# 80 + bits%64). printf "\U..." would need a UTF-8 locale; this does not.
_cu_braille_char() {
    local bits="$1" fmt
    printf -v fmt '\\xe2\\x%02x\\x%02x' $(( 0xa0 + (bits >> 6) )) $(( 0x80 + (bits & 63) ))
    # shellcheck disable=SC2059  # fmt holds only the \x escapes built above
    printf "$fmt"
}

# Read values from the arguments, or one per line from stdin, into _spark_values.
_cu_spark_read_values() {
    _spark_values=()
    if [ $# -gt 0 ]; then
        _spark_values=("$@")
    else
        local line
        while IFS= read -r line; do
            [ -n "$line" ] && _spark_values+=("$line")
        done
    fi
}

# Largest integer value at every STEP-th index of _spark_values, at least 1.
# Sparklines scale to the data maximum (floor 0), so low ranges such as
# 5-15% still show variation.
_cu_spark_scale() {
    local step="${1:-1}" max=0 j v
    for ((j = 0; j < ${#_spark_values[@]}; j += step)); do
        v="${_spark_values[$j]%.*}"; v="${v:-0}"
        [ "$v" -gt "$max" ] 2>/dev/null && max="$v"
    done
    [ "$max" -lt 1 ] && max=1
    echo "$max"
}

# Level 0..LEVELS of a value, clamped to [0, CU_SPARK_MAX] and scaled to
# SCALE, into _spark_level (a variable, not output: no subshell per value).
_cu_spark_level() {
    local v="${1%.*}" scale="$2" levels="$3" max="${CU_SPARK_MAX:-100}"
    v="${v:-0}"
    [ "$v" -lt 0 ] 2>/dev/null && v=0
    [ "$v" -gt "$max" ] 2>/dev/null && v="$max"
    _spark_level=$(( (v * levels) / scale ))
    [ "$_spark_level" -gt "$levels" ] && _spark_level="$levels"
    return 0
}

# Block sparkline (▁▂▃▄▅▆▇█), one character per value. With more values than
# CU_OPT_WIDTH it samples every n-th value.
cu_sparkline() {
    _cu_spark_read_values "$@"
    local count=${#_spark_values[@]}
    [ "$count" -eq 0 ] && return

    local width="${CU_OPT_WIDTH:-$count}" step=1
    [ "$count" -gt "$width" ] && step=$((count / width))

    local scale i written=0
    scale=$(_cu_spark_scale "$step")
    for ((i = 0; i < count && written < width; i += step)); do
        _cu_spark_level "${_spark_values[$i]}" "$scale" 7
        printf '%s' "${CU_SPARK_BLOCKS[$_spark_level]}"
        written=$((written + 1))
    done
}

# Braille sparkline, two values per character.
# CU_SPARK_RESETS (space-separated value indices) replaces the character that
# holds a reset with ↻.
cu_braille_sparkline() {
    _cu_spark_read_values "$@"
    local count=${#_spark_values[@]}
    [ "$count" -eq 0 ] && return

    local resets=" ${CU_SPARK_RESETS:-} "
    local scale i left right
    scale=$(_cu_spark_scale 1)
    for ((i = 0; i < count; i += 2)); do
        case "$resets" in
            *" $i "*|*" $((i + 1)) "*) printf '↻'; continue ;;
        esac
        _cu_spark_level "${_spark_values[$i]}" "$scale" 4
        left=$_spark_level
        right=0
        if [ $((i + 1)) -lt "$count" ]; then
            _cu_spark_level "${_spark_values[$((i + 1))]}" "$scale" 4
            right=$_spark_level
        fi
        _cu_braille_char $(( _CU_BRAILLE_LEFT[left] + _CU_BRAILLE_RIGHT[right] ))
    done
}

# Sparkline of usage growth per time slot for FIELD over the last HOURS.
# Args: field, hours, width (characters), mode (braille|block), tier
# Each slot shows how much utilization grew in it (in tenths of a point);
# drops (resets) count as 0.
# In braille mode a ↻ marks the slot where the window reset.
cu_sparkline_from_history() {
    local field="${1:-seven_day}" hours="${2:-168}" width="${3:-40}"
    local mode="${4:-}" tier="${5:-}"
    [ -z "$tier" ] && tier=$( [ "$field" = "five_hour" ] && echo short || echo long )

    # Braille shows two data points per character.
    local data_points="$width"
    [ "$mode" = "braille" ] && data_points=$((width * 2))

    local window_start slot_secs
    window_start=$(( $(cu_now) - hours * 3600 ))
    slot_secs=$(( (hours * 3600) / data_points ))

    # jq: TSV (ts, util, resets_at epoch). awk: interpolate utilization at each
    # slot boundary, emit per-slot growth (line 1) and reset slots (line 2).
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
                    # Reset boundary (drop > 5 points): snap to the nearer side
                    if (v1 - v0 < -5) {
                        mid = int((t0 + t1) / 2)
                        return (t <= mid) ? v0 : v1
                    }
                    return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
                }
            }
            return val[n-1]
        }
        { ts[n] = $1 + 0; val[n] = $2 + 0; ra[n] = $3 + 0; n++ }
        END {
            if (n == 0) exit 1

            # A reset shows as resets_at jumping forward by more than 5 minutes.
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

            for (i = 0; i < dp; i++) {
                s0 = win_start + i * slot_secs
                v_s = interp(s0)
                v_e = interp(s0 + slot_secs)
                # Tenths of a point: whole points would round small steps to 0.
                d = (v_s >= 0 && v_e >= 0) ? int((v_e - v_s) * 10) : 0
                printf "%s%d", (i > 0 ? " " : ""), (d < 0 ? 0 : d)
            }
            printf "\n"
            for (i = 0; i < rc; i++) printf "%s%d", (i > 0 ? " " : ""), resets[i]
            printf "\n"
        }')

    [ -z "$awk_output" ] && return

    local deltas_line reset_line
    { read -r deltas_line; read -r reset_line; } <<< "$awk_output"
    local -a deltas=()
    read -ra deltas <<< "$deltas_line"
    [ ${#deltas[@]} -eq 0 ] && return

    if [ "$mode" = "braille" ]; then
        CU_SPARK_MAX=1000 CU_SPARK_RESETS="$reset_line" cu_braille_sparkline "${deltas[@]}"
    else
        CU_SPARK_MAX=1000 CU_OPT_WIDTH="$width" cu_sparkline "${deltas[@]}"
    fi
}

# Progress bar: PCT of WIDTH cells filled. COLOR defaults to the percentage
# color (green/yellow/red).
cu_progress_bar() {
    local pct="${1:-0}" width="${2:-20}" color="${3:-}"
    pct="${pct%.*}"
    pct="${pct:-0}"
    [ "$pct" -gt 100 ] && pct=100
    [ "$pct" -lt 0 ] && pct=0
    [ -z "$color" ] && color=$(cu_pct_color "$pct")

    local filled=$(( (pct * width) / 100 ))
    local bar="" i
    bar+="$(cu_color "$color")"
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    bar+="$(cu_color "$CU_DIM")"
    for ((i = filled; i < width; i++)); do bar+="░"; done
    bar+="$(cu_reset)"
    printf '%s' "$bar"
}

# Percentage as a colored integer: "69%"
cu_fmt_pct() {
    local int_pct="${1%.*}"
    int_pct="${int_pct:-0}"
    printf "%s%d%%%s" "$(cu_color "$(cu_pct_color "$int_pct")")" "$int_pct" "$(cu_reset)"
}

# Rate per hour as "%.1f": "9.5"
cu_fmt_rate() {
    awk -v r="${1:-0}" 'BEGIN { printf "%.1f", r }'
}

# %/hour rate expressed per averaging window: "19%/1d", "10%/1h"
# Args: rate_per_hour, avg_window_hours
cu_fmt_rate_per_window() {
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

# Time to cap for a window: a duration for five_hour ("7h 24m"), a day and
# hour for seven_day ("Fri 3pm").
cu_fmt_eta() {
    local field="$1" secs="$2"
    case "$field" in
        seven_day) cu_fmt_eta_date "$secs" ;;
        *)         cu_fmt_duration "$secs" ;;
    esac
}

# Color for an ETA, from how it compares with the reset:
#   cap before reset (ratio < 100%) -> red
#   tight margin (100-120%)         -> yellow
#   comfortable (> 120%)            -> green
cu_eta_color() {
    local eta_secs="$1" reset_at="$2" secs_to_reset ratio
    secs_to_reset=$(cu_secs_until_reset "$reset_at")
    if [ "${secs_to_reset:-0}" -gt 0 ] 2>/dev/null && [ "$eta_secs" -gt 0 ] 2>/dev/null; then
        ratio=$(( eta_secs * 100 / secs_to_reset ))
        if [ "$ratio" -gt 120 ]; then echo "$CU_GREEN"; return; fi
        if [ "$ratio" -gt 100 ]; then echo "$CU_YELLOW"; return; fi
    fi
    echo "$CU_RED"
}
