#!/usr/bin/env bash
# dashboard.sh - Multi-line standalone terminal dashboard

cu_view_dashboard() {
    # Fetch + record history (don't abort on fetch failure under set -e)
    if [ "${CU_OPT_NO_FETCH:-}" != "1" ]; then
        cu_fetch || true
        local cache_data
        cache_data=$(cu_read_cache)
        [ -n "$cache_data" ] && cu_history_record "$cache_data"
    fi

    local data
    data=$(cu_read_cache)

    if [ -z "$data" ]; then
        echo "No usage data available. Run 'claude-usage fetch' first."
        return 1
    fi

    local five_pct seven_pct five_reset seven_reset
    five_pct=$(cu_get_five_hour_pct "$data")
    seven_pct=$(cu_get_seven_day_pct "$data")
    five_reset=$(cu_get_five_hour_reset "$data")
    seven_reset=$(cu_get_seven_day_reset "$data")

    # Header
    printf "%sClaude Usage%s\n" "$(cu_color "$CU_FG")" "$(cu_reset)"
    printf "%s============%s\n\n" "$(cu_color "$CU_DIM")" "$(cu_reset)"

    # 5-Hour Window (grouped: bar + sparkline + ETA + reset)
    if [ -n "$five_pct" ]; then
        local five_int="${five_pct%.*}"
        printf "%s5-Hour Window%s\n" "$(cu_color "$CU_FG")" "$(cu_reset)"
        printf "  %s  %s" "$(cu_progress_bar "$five_int" 20)" "$(cu_fmt_pct "$five_pct")"
        if [ -n "$five_reset" ]; then
            local secs
            secs=$(cu_secs_until_reset "$five_reset")
            [ "$secs" -gt 0 ] 2>/dev/null && printf "    %sresets in %s%s" "$(cu_color "$CU_DIM")" "$(cu_fmt_duration "$secs")" "$(cu_reset)"
        fi

        if [[ "${CU_ETA_WINDOWS}" == *"five_hour"* ]]; then
            local eta_info
            eta_info=$(cu_eta_projection "five_hour" "${CU_ETA_5H_AVG:-3}" 2>/dev/null || true)
            if [ -n "$eta_info" ]; then
                local rate eta_hours eta_secs before_reset
                read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
                if [ -n "${eta_hours:-}" ]; then
                    printf "\n  %s+%s%%/h | ~%s to cap" "+$rate" "$rate" "$(cu_fmt_duration "${eta_secs:-0}")"
                    [ "${before_reset:-}" = "1" ] && printf " | %sBEFORE RESET%s" "$(cu_color "$CU_RED")" "$(cu_reset)"
                fi
            fi
        fi

        local spark_short
        spark_short=$(cu_sparkline_from_history "five_hour" 5 20 "braille" 2>/dev/null || true)
        if [ -n "$spark_short" ]; then
            printf "\n  %sBurn rate:%s %s" "$(cu_color "$CU_DIM")" "$(cu_reset)" "$spark_short"
        fi
        printf "\n\n"
    fi

    # 7-Day Window (grouped: bar + sparkline + ETA + reset)
    if [ -n "$seven_pct" ]; then
        local seven_int="${seven_pct%.*}"
        printf "%s7-Day Window%s\n" "$(cu_color "$CU_FG")" "$(cu_reset)"
        printf "  %s  %s" "$(cu_progress_bar "$seven_int" 20)" "$(cu_fmt_pct "$seven_pct")"
        if [ -n "$seven_reset" ]; then
            local reset_date secs
            reset_date=$(cu_fmt_reset_date "$seven_reset")
            secs=$(cu_secs_until_reset "$seven_reset")
            if [ -n "$reset_date" ]; then
                printf "    %sresets %s" "$(cu_color "$CU_DIM")" "$reset_date"
                [ "$secs" -gt 0 ] 2>/dev/null && printf " (%s)" "$(cu_fmt_duration "$secs")"
                printf "%s" "$(cu_reset)"
            fi
        fi

        if [[ "${CU_ETA_WINDOWS}" == *"seven_day"* ]]; then
            local eta_info
            eta_info=$(cu_eta_projection "seven_day" "${CU_ETA_7D_AVG:-24}" 2>/dev/null || true)
            if [ -n "$eta_info" ]; then
                local rate eta_hours eta_secs before_reset
                read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
                if [ -n "${eta_hours:-}" ]; then
                    printf "\n  +%s%%/h | ~%s to cap" "$rate" "$(cu_fmt_duration "${eta_secs:-0}")"
                    [ "${before_reset:-}" = "1" ] && printf " | %sBEFORE RESET%s" "$(cu_color "$CU_RED")" "$(cu_reset)"
                fi
            fi
        fi

        local spark_long
        spark_long=$(cu_sparkline_from_history "seven_day" 168 20 "braille" 2>/dev/null || true)
        if [ -n "$spark_long" ]; then
            printf "\n  %sBurn rate:%s %s" "$(cu_color "$CU_DIM")" "$(cu_reset)" "$spark_long"
        fi
        printf "\n\n"
    fi
}
