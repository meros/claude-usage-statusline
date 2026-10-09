#!/usr/bin/env bash
# eta.sh - Burn rate and time-to-cap projections
#
# Two models:
#   - Flat rate (cu_eta_projection): consumption over the last N hours,
#     extrapolated linearly. Gives the burn rate shown by the rate module, and
#     the ETA for the 5h window.
#   - Seasonal template (cu_eta_template_seven_day): an hour-of-week profile
#     of past usage, walked forward to the reset. Gives the 7d ETA when there
#     is enough history, since weekly usage follows work hours.
# cu_window_eta picks the right one for a window.

# Seasonal template settings
CU_ETA_TEMPLATE="${CU_ETA_TEMPLATE:-1}"                   # 0 = flat rate for 7d too
CU_ETA_TEMPLATE_DAYS="${CU_ETA_TEMPLATE_DAYS:-28}"       # history the profile learns from
CU_ETA_TEMPLATE_MIN_DAYS="${CU_ETA_TEMPLATE_MIN_DAYS:-3}" # less history = no template

# Flat-rate projection to 100% for FIELD (five_hour|seven_day), from the
# consumption over the last AVG_WINDOW hours. TIER defaults to short, with a
# fallback to long when short has no data.
#
# Output: "rate_per_hour hours_to_cap secs_to_cap before_reset_flag"
#   before_reset_flag is 1 when the cap is reached before the window resets.
cu_eta_projection() {
    local field="${1:-seven_day}" avg_window="${2:-24}" tier="${3:-}"

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

    # Rate = sum of positive deltas over the window / window hours.
    #   - Only positive deltas count. A negative delta is a reset boundary
    #     (5h hard reset, 7d sliding decay or an API correction), never
    #     consumption.
    #   - The record just before the window start is the anchor, so a delta
    #     that straddles the window start still counts.
    #   - The denominator is wall-clock hours, so idle time lowers the rate.
    #   - No data or no positive deltas give rate 0, not an error.
    local result
    result=$(printf '%s\n' "$tsv_data" | awk -F'\t' -v window="$avg_window" '
        BEGIN { n = 0 }
        NF >= 2 {
            ts[n] = $1 + 0
            val[n] = $2 + 0
            n++
        }
        END {
            if (n < 1) {
                printf "0 0 0 "
                exit 0
            }

            t_end = ts[n-1]
            t_start = t_end - window * 3600

            anchor = -1
            for (i = 0; i < n; i++) {
                if (ts[i] <= t_start) anchor = i
                else break
            }
            # No record before t_start: start at the first record.
            first_in = (anchor >= 0) ? anchor + 1 : 1

            consumption = 0
            for (i = first_in; i < n; i++) {
                d = val[i] - val[i-1]
                if (d > 0) consumption += d
            }

            rate = (consumption > 0) ? consumption / window : 0

            remaining = 100 - val[n-1]
            if (rate > 0 && remaining > 0) {
                hours_to_cap = remaining / rate
                secs_to_cap = int(hours_to_cap * 3600)
            } else {
                hours_to_cap = 0
                secs_to_cap = 0
            }
            printf "%.4f %.1f %d", rate, hours_to_cap, secs_to_cap
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

    local reset_at before_reset=""
    reset_at=$(printf '%s\n' "$tsv_data" | tail -1 | cut -f3)
    if [ -n "$reset_at" ] && [ "${secs_to_cap:-0}" -gt 0 ] 2>/dev/null; then
        local secs_to_reset
        secs_to_reset=$(cu_secs_until_reset "$reset_at")
        [ "$secs_to_cap" -lt "$secs_to_reset" ] 2>/dev/null && before_reset=1
    fi

    printf "%s %s %s %s\n" "$rate" "$hours_to_cap" "$secs_to_cap" "$before_reset"
}

# --- Seasonal template ---------------------------------------------------
#
# "Seasonal mean" forecast (Hyndman & Athanasopoulos, FPP3 §5.2) with a weekly
# period of 168 hours:
#   1. Read the last CU_ETA_TEMPLATE_DAYS days of hourly history.
#   2. For each hour of the week (bucket = weekday * 24 + hour, Sunday 00:00
#      = 0) take the mean positive delta seen in that bucket.
#   3. Walk forward hour by hour from now to the reset, adding each bucket
#      mean to the current utilization. The first hour that crosses 100 is
#      the cap-hit time.
#
# Delta rules when building the buckets:
#   - skip pairs more than 2h apart (sleep, outage): the delta cannot be
#     attributed to one bucket
#   - skip pairs where both values are 0 (no activity yet; they would anchor
#     the mean at 0 before real data arrives)
#   - skip negative deltas (resets, sliding-window decay)
#   - a zero delta between non-zero values counts: a quiet active hour
#
# One awk program serves production and the debug trace (debug=1), so the two
# cannot drift apart. Input: TSV "ts util bucket". Last output line:
# "RESULT <secs_to_cap> <before_reset_flag>", secs 0 = no hit before reset.
# shellcheck disable=SC2016  # awk program, not shell
_CU_TEMPLATE_AWK='
BEGIN {
    n = 0
    for (i = 0; i < 168; i++) { sum[i] = 0; cnt[i] = 0 }
    split("Sun Mon Tue Wed Thu Fri Sat", days, " ")
}
NF >= 3 { ts[n] = $1 + 0; val[n] = $2 + 0; buc[n] = $3 + 0; n++ }
function bucket_name(b) { return sprintf("%s %02d:00", days[int(b / 24) + 1], b % 24) }
END {
    if (n < 2) exit 1

    for (i = 1; i < n; i++) {
        if (val[i-1] == 0 && val[i] == 0) continue
        gap = ts[i] - ts[i-1]
        if (gap <= 0 || gap > 7200) continue
        d = val[i] - val[i-1]
        if (d < 0) continue
        sum[buc[i]] += d
        cnt[buc[i]]++
    }

    total_burn = 0; nonempty = 0
    if (debug) {
        print "=== Hour-of-week bucket means (only non-empty) ==="
        print "Bucket layout: bucket = weekday(0=Sun..6=Sat) * 24 + hour-of-day\n"
    }
    for (b = 0; b < 168; b++) {
        burn[b] = (cnt[b] > 0) ? sum[b] / cnt[b] : 0
        total_burn += burn[b]
        if (cnt[b] > 0) {
            nonempty++
            if (debug) printf "  bucket %3d  %s  mean=%.3f%%/h  obs=%d\n", b, bucket_name(b), burn[b], cnt[b]
        }
    }
    if (debug) {
        printf "\n  filled buckets: %d/168  (empty buckets fall back to 0%%/h)\n\n", nonempty
        print "=== Forward projection walk ==="
        printf "Starting at util=%s%%, walking forward hour-by-hour to reset.\n\n", current_util
        print "  step  hour-of-week         expected   util-after  fallback?"
    }
    if (total_burn <= 0) exit 1

    # Bucket of each future hour = bucket of the last record + hours since it.
    projected = current_util + 0
    t = now
    anchor_ts = ts[n-1]
    anchor_buc = buc[n-1]
    hit_secs = -1
    max_steps = int(secs_to_reset / 3600) + 24

    for (step = 0; step < max_steps; step++) {
        hours_since = int((t - anchor_ts + 1800) / 3600)
        b = ((anchor_buc + hours_since) % 168 + 168) % 168  # awk % of negatives varies
        expected = burn[b]
        if (debug) printf "  %3d   %-22s %.3f     %.2f%%       %s\n", step, \
            sprintf("%s (b=%d)", bucket_name(b), b), expected, projected + expected, (cnt[b] == 0) ? "yes" : ""
        if (projected + expected >= 100) {
            # The cap is reached inside this hour: interpolate the fraction.
            frac = (expected > 0) ? (100 - projected) / expected : 0
            if (frac < 0) frac = 0
            if (frac > 1) frac = 1
            hit_secs = (t - now) + int(frac * 3600)
            break
        }
        projected += expected
        t += 3600
        if (t >= now + secs_to_reset) break
    }

    if (hit_secs >= 0 && hit_secs < secs_to_reset) printf "RESULT %d 1\n", hit_secs
    else printf "RESULT 0 0 %.2f\n", projected
}'

# TSV "ts util bucket" of the long tier for the template's lookback period.
_cu_template_input() {
    cu_history_read long $(( CU_ETA_TEMPLATE_DAYS * 24 )) | \
        jq -r 'select(.seven_day != null and .seven_day.util != null) |
            (.ts | localtime) as $lt |
            [.ts, .seven_day.util, ($lt[6] * 24 + $lt[3])] | @tsv' 2>/dev/null
}

_cu_distinct_days() {
    awk -F'\t' '{print int($1/86400)}' | sort -u | wc -l | tr -d ' '
}

# Seasonal-template ETA for the seven_day window.
# Args: current_util, secs_to_reset
# Output: "secs_to_cap before_reset_flag"; "0 " when the cap is not reached
# before the reset. Returns 1 with no output when history is too short.
cu_eta_template_seven_day() {
    local current_util="${1:-0}" secs_to_reset="${2:-0}"
    [ "${secs_to_reset%.*}" -gt 0 ] 2>/dev/null || return 1

    local tsv
    tsv=$(_cu_template_input)
    [ -z "$tsv" ] && return 1
    [ "$(printf '%s\n' "$tsv" | _cu_distinct_days)" -ge "$CU_ETA_TEMPLATE_MIN_DAYS" ] || return 1

    local result
    result=$(printf '%s\n' "$tsv" | awk -F'\t' -v debug=0 -v now="$(cu_now)" \
        -v current_util="$current_util" -v secs_to_reset="$secs_to_reset" \
        "$_CU_TEMPLATE_AWK" 2>/dev/null) || return 1
    [ -z "$result" ] && return 1

    local _tag secs flag
    read -r _tag secs flag _ <<< "$result"
    if [ "$flag" = "1" ]; then
        printf "%s 1\n" "$secs"
    else
        printf "0 \n"
    fi
}

# Print the template's inputs, bucket means and hour-by-hour walk.
# Args: current_util, secs_to_reset
cu_debug_template_seven_day() {
    local current_util="${1:-0}" secs_to_reset="${2:-0}"
    local now
    now=$(cu_now)

    printf "=== Inputs ===\n"
    printf "now             : %d (%s)\n" "$now" "$(date -d "@$now" '+%a %Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "$now" '+%a %Y-%m-%d %H:%M %Z' 2>/dev/null)"
    printf "current util    : %s%%\n" "$current_util"
    printf "secs_to_reset   : %d (%s)\n" "$secs_to_reset" "$(cu_fmt_duration "$secs_to_reset")"
    printf "lookback        : %dh (%dd)\n" "$(( CU_ETA_TEMPLATE_DAYS * 24 ))" "$CU_ETA_TEMPLATE_DAYS"
    echo

    local tsv
    tsv=$(_cu_template_input)
    if [ -z "$tsv" ]; then
        printf "No long-tier seven_day history available — template cannot run.\n"
        return 1
    fi

    local distinct_days
    distinct_days=$(printf '%s\n' "$tsv" | _cu_distinct_days)
    printf "=== Template input ===\n"
    printf "records          : %d\n" "$(printf '%s\n' "$tsv" | wc -l)"
    printf "distinct days    : %d\n" "$distinct_days"
    if [ "$distinct_days" -lt "$CU_ETA_TEMPLATE_MIN_DAYS" ]; then
        printf "\nFewer than %d distinct days — production function would bail.\n" "$CU_ETA_TEMPLATE_MIN_DAYS"
    fi
    echo

    local trace
    trace=$(printf '%s\n' "$tsv" | awk -F'\t' -v debug=1 -v now="$now" \
        -v current_util="$current_util" -v secs_to_reset="$secs_to_reset" \
        "$_CU_TEMPLATE_AWK")
    printf '%s\n' "$trace" | grep -v '^RESULT '

    local _tag secs flag final
    read -r _tag secs flag final <<< "$(printf '%s\n' "$trace" | grep '^RESULT ')"
    if [ "$flag" = "1" ]; then
        printf "\n  *** Cap projected to hit at %s after %d secs (before reset) ***\n" \
            "$(date -d "@$((now + secs))" '+%a %Y-%m-%d %H:%M' 2>/dev/null || date -r "$((now + secs))" '+%a %Y-%m-%d %H:%M')" "$secs"
    elif [ -n "$final" ]; then
        printf "\n  *** Reached reset at %s without crossing 100%%. Final projected util=%s%% ***\n" \
            "$(date -d "@$((now + secs_to_reset))" '+%a %H:%M' 2>/dev/null || date -r "$((now + secs_to_reset))" '+%a %H:%M')" "$final"
    fi
}

# Projection for one window, in shared variables:
#   _eta_rate      burn rate, %/hour (flat rate; "0" without data)
#   _eta_secs      seconds to 100% (0 or empty = no projection)
#   _before_reset  1 when 100% comes before the window resets
# Args: field, avg_window_hours, current_pct, resets_at_iso
cu_window_eta() {
    local field="$1" avg_window="$2" pct="${3:-0}" reset_at="${4:-}"
    local _eta_hours
    _eta_rate="" _eta_secs="" _before_reset=""

    local eta_info
    eta_info=$(cu_eta_projection "$field" "$avg_window" 2>/dev/null || true)
    if [ -n "$eta_info" ]; then
        read -r _eta_rate _eta_hours _eta_secs _before_reset <<< "$eta_info"
    else
        _eta_rate="0"
    fi

    # The 7d window follows work hours, so prefer the seasonal template.
    [ "$field" = "seven_day" ] && [ "$CU_ETA_TEMPLATE" = "1" ] && [ -n "$reset_at" ] || return 0
    local secs_to_reset tmpl
    secs_to_reset=$(cu_secs_until_reset "$reset_at")
    [ "${secs_to_reset:-0}" -gt 0 ] 2>/dev/null || return 0
    pct="${pct%.*}"
    tmpl=$(cu_eta_template_seven_day "${pct:-0}" "$secs_to_reset" 2>/dev/null || true)
    [ -n "$tmpl" ] && read -r _eta_secs _before_reset <<< "$tmpl"
    return 0
}
