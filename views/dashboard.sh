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

    local _win
    for _win in ${CU_WINDOWS//,/ }; do
        local win_label win_pct win_reset win_field eta_avg spark_hours spark_tier
        case "$_win" in
            five_hour)
                win_label="5-Hour Window"
                win_pct="$five_pct"
                win_reset="$five_reset"
                win_field="five_hour"
                eta_avg="${CU_ETA_5H_AVG:-3}"
                spark_hours=5
                spark_tier="short"
                ;;
            seven_day)
                win_label="7-Day Window"
                win_pct="$seven_pct"
                win_reset="$seven_reset"
                win_field="seven_day"
                eta_avg="${CU_ETA_7D_AVG:-24}"
                spark_hours=168
                spark_tier="long"
                ;;
            *) continue ;;
        esac

        [ -z "$win_pct" ] && continue
        local pct_int="${win_pct%.*}"

        printf "%s%s%s\n" "$(cu_color "$CU_FG")" "$win_label" "$(cu_reset)"
        printf "  %s  %s" "$(cu_progress_bar "$pct_int" 20)" "$(cu_fmt_pct "$win_pct")"

        if [ -n "$win_reset" ]; then
            local secs
            secs=$(cu_secs_until_reset "$win_reset")
            if [ "$_win" = "seven_day" ]; then
                local reset_date
                reset_date=$(cu_fmt_reset_date "$win_reset")
                if [ -n "$reset_date" ]; then
                    printf "    %sresets %s" "$(cu_color "${CU_COLOR_RESET}")" "$reset_date"
                    [ "$secs" -gt 0 ] 2>/dev/null && printf " (%s)" "$(cu_fmt_duration "$secs")"
                    printf "%s" "$(cu_reset)"
                fi
            else
                [ "$secs" -gt 0 ] 2>/dev/null && printf "    %sresets in %s%s" "$(cu_color "${CU_COLOR_RESET}")" "$(cu_fmt_duration "$secs")" "$(cu_reset)"
            fi
        fi

        local eta_info
        eta_info=$(cu_eta_projection "$win_field" "$eta_avg" 2>/dev/null || true)
        if [ -n "$eta_info" ]; then
            local rate eta_hours eta_secs before_reset
            read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
            if [ -n "${eta_hours:-}" ]; then
                local eta_str
                case "$_win" in
                    seven_day) eta_str=$(cu_fmt_eta_date "${eta_secs:-0}") ;;
                    *)         eta_str=$(cu_fmt_duration "${eta_secs:-0}") ;;
                esac
                printf "\n  +%s%%/h | ~%s to cap" "$rate" "$eta_str"
                [ "${before_reset:-}" = "1" ] && printf " | %sBEFORE RESET%s" "$(cu_color "${CU_COLOR_WARN}")" "$(cu_reset)"
            fi
        fi

        local spark_mode="${CU_SPARKLINE_TYPE:-braille}"
        [ "$spark_mode" != "block" ] && spark_mode="braille"
        local spark
        spark=$(cu_sparkline_from_history "$win_field" "$spark_hours" 20 "$spark_mode" "$spark_tier" 2>/dev/null || true)
        if [ -n "$spark" ]; then
            printf "\n  %sBurn rate:%s %s%s%s" \
                "$(cu_color "$CU_DIM")" "$(cu_reset)" \
                "$(cu_color "${CU_COLOR_SPARKLINE}")" "$spark" "$(cu_reset)"
        fi
        printf "\n\n"
    done
}
