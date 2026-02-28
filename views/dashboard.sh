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

    # 5-Hour Window
    if [ -n "$five_pct" ]; then
        local five_int="${five_pct%.*}"
        printf "%s5-Hour Window%s\n" "$(cu_color "$CU_FG")" "$(cu_reset)"
        printf "  %s  %s" "$(cu_progress_bar "$five_int" 20)" "$(cu_fmt_pct "$five_pct")"
        if [ -n "$five_reset" ]; then
            local secs
            secs=$(cu_secs_until_reset "$five_reset")
            if [ "$secs" -gt 0 ] 2>/dev/null; then
                printf "    %sresets in %s%s" "$(cu_color "$CU_DIM")" "$(cu_fmt_duration "$secs")" "$(cu_reset)"
            fi
        fi
        printf "\n\n"
    fi

    # 7-Day Window
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
                if [ "$secs" -gt 0 ] 2>/dev/null; then
                    printf " (%s)" "$(cu_fmt_duration "$secs")"
                fi
                printf "%s" "$(cu_reset)"
            fi
        fi
        printf "\n\n"
    fi

    # Sparkline history
    local spark
    spark=$(cu_sparkline_from_history "seven_day" 168 40 2>/dev/null)
    if [ -n "$spark" ]; then
        printf "  %sHourly (last 7 days):%s\n" "$(cu_color "$CU_DIM")" "$(cu_reset)"
        printf "  %s\n\n" "$spark"
    fi

    # ETA Projections for each configured window
    local _eta_win
    for _eta_win in ${CU_ETA_WINDOWS//,/ }; do
        local _eta_field="" _eta_avg="" _eta_label=""
        case "$_eta_win" in
            five_hour) _eta_field="five_hour"; _eta_avg="${CU_ETA_5H_AVG:-3}"; _eta_label="5-Hour" ;;
            seven_day) _eta_field="seven_day"; _eta_avg="${CU_ETA_7D_AVG:-24}"; _eta_label="7-Day" ;;
            *) continue ;;
        esac
        local eta_info
        eta_info=$(cu_eta_projection "$_eta_field" "$_eta_avg" 2>/dev/null || true)
        if [ -n "$eta_info" ]; then
            local rate eta_hours eta_secs before_reset
            read -r rate eta_hours eta_secs before_reset <<< "$eta_info"
            if [ -n "${eta_hours:-}" ]; then
                printf "%s${_eta_label} Projection:%s " "$(cu_color "$CU_FG")" "$(cu_reset)"
                printf "+%s%%/h" "$rate"
                local eta_dur
                eta_dur=$(cu_fmt_duration "${eta_secs:-0}")
                printf " | ~%s to 100%%" "$eta_dur"
                if [ "${before_reset:-}" = "1" ]; then
                    printf " | %sBEFORE RESET%s" "$(cu_color "$CU_RED")" "$(cu_reset)"
                fi
                printf "\n"
            fi
        fi
    done
}
