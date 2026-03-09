#!/usr/bin/env bash
# history.sh - Dual-tier JSONL history: short (5-min) + long (hourly)

# Short tier: 5-min intervals, 36h retention, both fields (fine-grained for ETA)
# Retention covers the largest ETA avg window (CU_ETA_7D_AVG=24h) plus margin
CU_HISTORY_SHORT="${CU_DATA_DIR}/history-short.jsonl"
CU_SHORT_INTERVAL=300        # 5 minutes in seconds
CU_SHORT_MAX_AGE=129600      # 36 hours

# Long tier: hourly intervals, 1-year retention, seven_day field only
CU_HISTORY_LONG="${CU_DATA_DIR}/history-long.jsonl"
CU_LONG_INTERVAL=3600        # 1 hour in seconds
CU_LONG_MAX_AGE=31536000     # 365 days

_CU_MIGRATED=""

cu_tier_for_field() {
    case "$1" in five_hour) echo short ;; *) echo long ;; esac
}

cu_history_record() {
    local data="${1:-$(cu_read_cache)}"
    [ -z "$data" ] && return 1

    # Auto-migrate old single-file history on first call
    if [ -z "$_CU_MIGRATED" ]; then
        cu_history_migrate
        _CU_MIGRATED=1
    fi

    local now
    now=$(cu_now)

    # Short tier: 5-min dedup, both fields (fine-grained data for ETA calculations)
    local has_five_hour has_seven_day_short
    has_five_hour=$(echo "$data" | jq -e '.five_hour' >/dev/null 2>&1 && echo 1 || echo 0)
    has_seven_day_short=$(echo "$data" | jq -e '.seven_day' >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$has_five_hour" = "1" ] || [ "$has_seven_day_short" = "1" ]; then
        local short_bucket=$((now / CU_SHORT_INTERVAL))
        local write_short=1
        if [ -f "$CU_HISTORY_SHORT" ]; then
            local last_ts
            last_ts=$(tail -1 "$CU_HISTORY_SHORT" 2>/dev/null | jq -r '.ts // 0' 2>/dev/null)
            local last_bucket=$((last_ts / CU_SHORT_INTERVAL))
            [ "$short_bucket" = "$last_bucket" ] && write_short=0
        fi
        if [ "$write_short" = "1" ]; then
            local short_line
            short_line=$(echo "$data" | jq -c --argjson ts "$now" \
                '{ts: $ts}
                + (if .five_hour then {five_hour: {util: .five_hour.utilization, resets_at: (.five_hour.resets_at // "")}} else {} end)
                + (if .seven_day then {seven_day: {util: .seven_day.utilization, resets_at: (.seven_day.resets_at // "")}} else {} end)' \
                2>/dev/null) || true
            [ -n "$short_line" ] && echo "$short_line" >> "$CU_HISTORY_SHORT"
        fi
    fi

    # Long tier: hourly dedup, seven_day field only
    local has_seven_day
    has_seven_day=$(echo "$data" | jq -e '.seven_day' >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$has_seven_day" = "1" ]; then
        local long_bucket=$((now / CU_LONG_INTERVAL))
        local write_long=1
        if [ -f "$CU_HISTORY_LONG" ]; then
            local last_ts
            last_ts=$(tail -1 "$CU_HISTORY_LONG" 2>/dev/null | jq -r '.ts // 0' 2>/dev/null)
            local last_bucket=$((last_ts / CU_LONG_INTERVAL))
            [ "$long_bucket" = "$last_bucket" ] && write_long=0
        fi
        if [ "$write_long" = "1" ]; then
            local long_line
            long_line=$(echo "$data" | jq -c --argjson ts "$now" \
                '{ts: $ts, seven_day: {util: .seven_day.utilization, resets_at: (.seven_day.resets_at // "")}}' \
                2>/dev/null) || true
            [ -n "$long_line" ] && echo "$long_line" >> "$CU_HISTORY_LONG"
        fi
    fi
}

cu_history_prune() {
    local now
    now=$(cu_now)

    # Prune short tier (24h)
    if [ -f "$CU_HISTORY_SHORT" ]; then
        local cutoff=$((now - CU_SHORT_MAX_AGE))
        local tmp="${CU_HISTORY_SHORT}.tmp"
        if jq -R -c --argjson cutoff "$cutoff" 'fromjson? | select(.ts >= $cutoff)' "$CU_HISTORY_SHORT" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$CU_HISTORY_SHORT"
        else
            rm -f "$tmp"
        fi
    fi

    # Prune long tier (1 year)
    if [ -f "$CU_HISTORY_LONG" ]; then
        local cutoff=$((now - CU_LONG_MAX_AGE))
        local tmp="${CU_HISTORY_LONG}.tmp"
        if jq -R -c --argjson cutoff "$cutoff" 'fromjson? | select(.ts >= $cutoff)' "$CU_HISTORY_LONG" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$CU_HISTORY_LONG"
        else
            rm -f "$tmp"
        fi
    fi
}

cu_history_read() {
    local tier="${1:-long}" hours="${2:-168}"
    local now cutoff file
    now=$(cu_now)
    cutoff=$((now - hours * 3600))

    case "$tier" in
        short) file="$CU_HISTORY_SHORT" ;;
        long)  file="$CU_HISTORY_LONG" ;;
        *)     file="$CU_HISTORY_LONG" ;;
    esac

    [ -f "$file" ] || return 0
    jq -R -c --argjson cutoff "$cutoff" 'fromjson? | select(.ts >= $cutoff)' "$file" 2>/dev/null
}

cu_history_values() {
    local tier="${1:-long}" field="${2:-seven_day}" hours="${3:-168}"
    cu_history_read "$tier" "$hours" | jq -r ".$field.util" 2>/dev/null
}

cu_history_deltas() {
    # Output per-interval deltas (rate of change) instead of absolute values
    # Negative deltas (resets) are clamped to 0
    local tier="${1:-long}" field="${2:-seven_day}" hours="${3:-168}"
    local prev="" val=""
    while IFS= read -r val; do
        [ -z "$val" ] && continue
        if [ -n "$prev" ]; then
            local prev_int="${prev%.*}" val_int="${val%.*}"
            prev_int="${prev_int:-0}"; val_int="${val_int:-0}"
            local delta=$((val_int - prev_int))
            # Clamp negative deltas (resets) to 0
            [ "$delta" -lt 0 ] 2>/dev/null && delta=0
            echo "$delta"
        fi
        prev="$val"
    done < <(cu_history_values "$tier" "$field" "$hours")
}

cu_history_dump() {
    if [ -f "$CU_HISTORY_SHORT" ]; then
        echo "=== Short tier (5-min, 24h) ==="
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

        local now
        now=$(cu_now)
        local short_cutoff=$((now - CU_SHORT_MAX_AGE))

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

    # Read long tier into sorted arrays of (ts, util) for interpolation
    # Then enrich each short tier record with an interpolated seven_day value
    local tmp="${CU_HISTORY_SHORT}.mig"
    jq -c --slurpfile long <(jq -c '{ts, util: .seven_day.util}' "$CU_HISTORY_LONG" 2>/dev/null) '
        . as $rec |
        ($long | sort_by(.ts)) as $pts |
        if ($pts | length) < 1 then $rec
        else
            # Find surrounding long-tier points and linearly interpolate
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
