#!/usr/bin/env bash
# demo.sh - Deterministic demo dataset for snapshot tests and README screenshots
#
# demo_build DATA_DIR CACHE_DIR writes four weeks of hourly history, 36 hours
# of 5-minute history and a matching API cache. "Now" is fixed at
# Wed 2026-10-07 14:20 Europe/Stockholm, so run with TZ=Europe/Stockholm and
# CU_NOW="$DEMO_NOW".

DEMO_NOW=1791375600          # Wed 2026-10-07 14:20 CEST
DEMO_FIVE_RESET=1791380400   # Wed 2026-10-07 15:40 CEST
DEMO_SEVEN_RESET=1791529200  # Fri 2026-10-09 09:00 CEST

# Claude Code statusline stdin, with or without the rate_limits block.
demo_stdin() {
    local cwd="$1" with_limits="${2:-1}"
    if [ "$with_limits" = "1" ]; then
        jq -cn --arg cwd "$cwd" --argjson f "$DEMO_FIVE_RESET" --argjson s "$DEMO_SEVEN_RESET" '{
            workspace: {current_dir: $cwd},
            model: {display_name: "Opus"},
            rate_limits: {
                five_hour: {used_percentage: 30, resets_at: $f},
                seven_day: {used_percentage: 69, resets_at: $s}
            }
        }'
    else
        jq -cn --arg cwd "$cwd" '{workspace: {current_dir: $cwd}, model: {display_name: "Opus"}}'
    fi
}

demo_build() {
    local data_dir="$1" cache_dir="$2"
    mkdir -p "$data_dir" "$cache_dir"

    # Usage model, in local time (CEST, UTC+2, for the whole period):
    #   - weekdays 08-18 burn 1-2.6 %/h of the weekly cap, evenings a little,
    #     weekends almost nothing; the weekly cap resets Fri 09:00
    #   - the 5-hour cap burns 4x the weekly rate and resets every 5 hours,
    #     with the current window ending 15:40
    # A fixed hash replaces rand() so every awk gives the same numbers.
    awk -v now="$DEMO_NOW" -v seven_reset="$DEMO_SEVEN_RESET" -v five_reset="$DEMO_FIVE_RESET" \
        -v long_out="$data_dir/history-long.jsonl" -v short_out="$data_dir/history-short.jsonl" '
        function noise(i) { return ((i * 7919 + 104729) % 1000) / 1000 }
        function burn(t,    lt, dow, hr, i) {
            lt = t + 7200
            dow = (int(lt / 86400) + 4) % 7          # 0 = Sunday
            hr = int((lt % 86400) / 3600)
            i = int(t / 3600)
            if (dow >= 1 && dow <= 5 && hr >= 8 && hr < 18) return 1.0 + 1.6 * noise(i)
            if (dow >= 1 && dow <= 5 && hr >= 19 && hr < 22) return 0.4 * noise(i)
            return (noise(i) > 0.9) ? 0.3 : 0
        }
        BEGIN {
            week = 7 * 86400
            start = now - 28 * 86400
            # Integrate the weekly burn from 5 weeks back so the first record
            # already sits mid-cycle.
            seven = 0; five = 0
            last_seven_reset = seven_reset - 5 * week
            last_five_reset = five_reset - int((five_reset - (start - 2 * week)) / 18000) * 18000
            for (t = start - 2 * week; t <= now; t += 300) {
                while (t >= last_seven_reset + week) { last_seven_reset += week; seven = 0 }
                while (t >= last_five_reset + 18000) { last_five_reset += 18000; five = 0 }
                b = burn(t) / 12
                seven += b; five += 4 * b
                if (seven > 100) seven = 100
                if (five > 100) five = 100
                if (t < start) continue
                if ((t - start) % 3600 == 0)
                    printf "{\"ts\":%d,\"seven_day\":{\"util\":%.1f,\"resets_at\":\"%s\"}}\n", \
                        t, seven, last_seven_reset + week > long_out
                if (t >= now - 36 * 3600)
                    printf "{\"ts\":%d,\"five_hour\":{\"util\":%.1f,\"resets_at\":\"%s\"},\"seven_day\":{\"util\":%.1f,\"resets_at\":\"%s\"}}\n", \
                        t, five, last_five_reset + 18000, seven, last_seven_reset + week > short_out
            }
        }'

    # resets_at was written as an epoch placeholder; convert to ISO 8601 UTC.
    local f
    for f in "$data_dir/history-long.jsonl" "$data_dir/history-short.jsonl"; do
        jq -c '(.. | objects | select(has("resets_at")) | .resets_at) |= (tonumber | todate)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done

    jq -n --argjson f "$DEMO_FIVE_RESET" --argjson s "$DEMO_SEVEN_RESET" '{
        five_hour: {utilization: 30, resets_at: ($f | todate)},
        seven_day: {utilization: 69, resets_at: ($s | todate)}
    }' > "$cache_dir/api-response.json"
}
