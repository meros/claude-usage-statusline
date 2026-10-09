#!/usr/bin/env bash
# history.sh - Two-tier JSONL usage history
#
# Short tier: one record per 5 minutes, kept 36 hours, both windows. Feeds the
#             burn rate and the 5h sparkline. 36h covers the largest default
#             rate window (CU_ETA_7D_AVG=24h) with margin.
# Long tier:  one record per hour, kept 1 year, seven_day only. Feeds the 7d
#             sparkline and the seasonal ETA template.
#
# Record format: {"ts": <epoch>, "five_hour": {"util": N, "resets_at": "<iso>"}, "seven_day": {...}}

CU_SHORT_INTERVAL=300        # 5 minutes
CU_SHORT_MAX_AGE=129600      # 36 hours
CU_LONG_INTERVAL=3600        # 1 hour
CU_LONG_MAX_AGE=31536000     # 365 days

_CU_MIGRATED=""

cu_history_file() {
    case "$1" in
        short) echo "$CU_HISTORY_SHORT" ;;
        *)     echo "$CU_HISTORY_LONG" ;;
    esac
}

# Append LINE to FILE unless the last record falls in the same INTERVAL bucket.
_cu_history_append() {
    local file="$1" interval="$2" now="$3" line="$4"
    [ -n "$line" ] || return 0
    if [ -f "$file" ]; then
        local last_ts
        last_ts=$(tail -1 "$file" 2>/dev/null | tr -d '\0' | jq -r '.ts // 0' 2>/dev/null)
        [ $(( now / interval )) = $(( ${last_ts:-0} / interval )) ] && return 0
    fi
    echo "$line" >> "$file"
}

# Record a cache payload (default: the cache file) into both tiers.
cu_history_record() {
    local data="${1:-$(cu_read_cache)}"
    [ -z "$data" ] && return 1

    # Auto-migrate old single-file history on first call
    if [ -z "$_CU_MIGRATED" ]; then
        cu_history_migrate
        _CU_MIGRATED=1
    fi

    local now short_line long_line
    now=$(cu_now)
    short_line=$(echo "$data" | jq -c --argjson ts "$now" '
        def rec: {util: .utilization, resets_at: (.resets_at // "")};
        if (.five_hour or .seven_day) then
            {ts: $ts}
            + (if .five_hour then {five_hour: (.five_hour | rec)} else {} end)
            + (if .seven_day then {seven_day: (.seven_day | rec)} else {} end)
        else empty end' 2>/dev/null) || true
    long_line=$(echo "$data" | jq -c --argjson ts "$now" '
        if .seven_day then
            {ts: $ts, seven_day: {util: .seven_day.utilization, resets_at: (.seven_day.resets_at // "")}}
        else empty end' 2>/dev/null) || true

    _cu_history_append "$CU_HISTORY_SHORT" "$CU_SHORT_INTERVAL" "$now" "$short_line"
    _cu_history_append "$CU_HISTORY_LONG" "$CU_LONG_INTERVAL" "$now" "$long_line"
}

# Refresh the cache (unless --no-fetch) and record it into history.
cu_fetch_and_record() {
    [ "${CU_OPT_NO_FETCH:-}" = "1" ] && return 0
    cu_fetch || return 1
    local data
    data=$(cu_read_cache)
    [ -n "$data" ] && cu_history_record "$data"
    return 0
}

# Drop records older than MAX_AGE from FILE; skips unparseable lines.
_cu_history_prune_file() {
    local file="$1" max_age="$2"
    [ -f "$file" ] || return 0
    local tmp="${file}.tmp"
    if jq -R -c --argjson cutoff "$(( $(cu_now) - max_age ))" \
        'fromjson? | select(.ts >= $cutoff)' "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
}

cu_history_prune() {
    _cu_history_prune_file "$CU_HISTORY_SHORT" "$CU_SHORT_MAX_AGE"
    _cu_history_prune_file "$CU_HISTORY_LONG" "$CU_LONG_MAX_AGE"
}

# Print the records of TIER from the last HOURS hours, one JSON object per line.
cu_history_read() {
    local tier="${1:-long}" hours="${2:-168}"
    local file cutoff
    file=$(cu_history_file "$tier")
    cutoff=$(( $(cu_now) - hours * 3600 ))
    [ -f "$file" ] || return 0
    jq -R -c --argjson cutoff "$cutoff" 'fromjson? | select(.ts >= $cutoff)' "$file" 2>/dev/null
}

cu_history_values() {
    local tier="${1:-long}" field="${2:-seven_day}" hours="${3:-168}"
    cu_history_read "$tier" "$hours" | jq -r ".$field.util" 2>/dev/null
}

cu_history_dump() {
    if [ -f "$CU_HISTORY_SHORT" ]; then
        echo "=== Short tier (5-min, 36h) ==="
        cat "$CU_HISTORY_SHORT"
    fi
    if [ -f "$CU_HISTORY_LONG" ]; then
        echo "=== Long tier (hourly, 1yr) ==="
        cat "$CU_HISTORY_LONG"
    fi
}

cu_history_migrate() {
    # Migration 1: old single-file → dual-tier
    local old_file="${CU_DATA_DIR}/history.jsonl"
    if [ -f "$old_file" ] && [ ! -f "${old_file}.bak" ] \
       && [ ! -f "$CU_HISTORY_SHORT" ] && [ ! -f "$CU_HISTORY_LONG" ]; then

        local short_cutoff=$(( $(cu_now) - CU_SHORT_MAX_AGE ))

        # Migrate recent → short (both fields), all → long (seven_day only)
        jq -c --argjson cutoff "$short_cutoff" \
            'select(.ts >= $cutoff) | {ts} + (if .five_hour then {five_hour} else {} end) + (if .seven_day then {seven_day} else {} end)' \
            "$old_file" > "$CU_HISTORY_SHORT" 2>/dev/null || true

        jq -c 'select(.seven_day) | {ts, seven_day}' \
            "$old_file" > "$CU_HISTORY_LONG" 2>/dev/null || true

        [ -s "$CU_HISTORY_SHORT" ] || rm -f "$CU_HISTORY_SHORT"
        [ -s "$CU_HISTORY_LONG" ] || rm -f "$CU_HISTORY_LONG"

        mv "$old_file" "${old_file}.bak"
    fi

    # Migration 2: backfill seven_day into short tier by interpolating from long tier
    _cu_migrate_short_seven_day
}

_cu_migrate_short_seven_day() {
    [ -f "$CU_HISTORY_SHORT" ] || return 0
    [ -f "$CU_HISTORY_LONG" ] || return 0

    # Quick check: if first record already has seven_day, no migration needed
    if head -1 "$CU_HISTORY_SHORT" | jq -e '.seven_day' >/dev/null 2>&1; then
        return 0
    fi

    # Enrich each short-tier record with a seven_day value interpolated
    # linearly between the surrounding long-tier records.
    local tmp="${CU_HISTORY_SHORT}.mig"
    jq -c --slurpfile long <(jq -c '{ts, util: .seven_day.util}' "$CU_HISTORY_LONG" 2>/dev/null) '
        . as $rec |
        ($long | sort_by(.ts)) as $pts |
        if ($pts | length) < 1 then $rec
        else
            ($rec.ts) as $t |
            ([$pts[] | select(.ts <= $t)] | last // null) as $lo |
            ([$pts[] | select(.ts > $t)] | first // null) as $hi |
            if $lo == null and $hi == null then $rec
            elif $lo == null then $rec + {seven_day: {util: $hi.util, resets_at: ""}}
            elif $hi == null then $rec + {seven_day: {util: $lo.util, resets_at: ""}}
            elif $lo.ts == $hi.ts then $rec + {seven_day: {util: $lo.util, resets_at: ""}}
            else
                (($t - $lo.ts) / ($hi.ts - $lo.ts)) as $frac |
                ($lo.util + ($hi.util - $lo.util) * $frac) as $interp |
                $rec + {seven_day: {util: $interp, resets_at: ""}}
            end
        end
    ' "$CU_HISTORY_SHORT" > "$tmp" 2>/dev/null

    if [ -s "$tmp" ]; then
        mv "$tmp" "$CU_HISTORY_SHORT"
    else
        rm -f "$tmp"
    fi
}
