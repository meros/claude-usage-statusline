#!/usr/bin/env bash
# history.sh - JSONL append/query with hourly dedup, 14-day prune

CU_HISTORY_FILE="${CU_DATA_DIR}/history.jsonl"
CU_HISTORY_MAX_AGE="${CU_HISTORY_MAX_AGE:-1209600}" # 14 days in seconds

cu_history_record() {
    local data="${1:-$(cu_read_cache)}"
    [ -z "$data" ] && return 1

    local now
    now=$(cu_now)

    # Deduplicate by hour: skip if last entry is within the same hour
    local hour_bucket=$((now / 3600))
    if [ -f "$CU_HISTORY_FILE" ]; then
        local last_ts
        last_ts=$(tail -1 "$CU_HISTORY_FILE" 2>/dev/null | jq -r '.ts // 0' 2>/dev/null)
        local last_bucket=$((last_ts / 3600))
        if [ "$hour_bucket" = "$last_bucket" ]; then
            return 0
        fi
    fi

    # Build record with only the windows present in the API response
    local line
    line=$(echo "$data" | jq -c --argjson ts "$now" '
        {ts: $ts}
        + (if .five_hour then {five_hour: {util: .five_hour.utilization, resets_at: (.five_hour.resets_at // "")}} else {} end)
        + (if .seven_day then {seven_day: {util: .seven_day.utilization, resets_at: (.seven_day.resets_at // "")}} else {} end)
    ' 2>/dev/null) || return 1

    echo "$line" >> "$CU_HISTORY_FILE"
}

cu_history_prune() {
    [ -f "$CU_HISTORY_FILE" ] || return 0
    local now cutoff
    now=$(cu_now)
    cutoff=$((now - CU_HISTORY_MAX_AGE))

    local tmp="${CU_HISTORY_FILE}.tmp"
    if jq -c --argjson cutoff "$cutoff" 'select(.ts >= $cutoff)' "$CU_HISTORY_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$CU_HISTORY_FILE"
    else
        rm -f "$tmp"
    fi
}

cu_history_read() {
    local hours="${1:-168}" # default 7 days
    local now cutoff
    now=$(cu_now)
    cutoff=$((now - hours * 3600))

    [ -f "$CU_HISTORY_FILE" ] || return 0
    jq -c --argjson cutoff "$cutoff" 'select(.ts >= $cutoff)' "$CU_HISTORY_FILE" 2>/dev/null
}

cu_history_values() {
    local field="${1:-seven_day}" hours="${2:-168}"
    cu_history_read "$hours" | jq -r ".$field.util" 2>/dev/null
}

cu_history_dump() {
    [ -f "$CU_HISTORY_FILE" ] && cat "$CU_HISTORY_FILE"
}
