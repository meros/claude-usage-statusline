#!/usr/bin/env bash
# dashboard.sh - Full terminal dashboard (claude-usage show)

cu_view_dashboard() {
    cu_fetch_and_record || true

    local data
    data=$(cu_read_cache)
    if [ -z "$data" ]; then
        echo "No usage data available. Run 'claude-usage fetch' first."
        return 1
    fi

    printf "%sClaude Usage%s\n" "$(cu_color "$CU_FG")" "$(cu_reset)"
    printf "%s============%s\n\n" "$(cu_color "$CU_DIM")" "$(cu_reset)"

    local win
    for win in $(cu_words "$CU_WINDOWS"); do
        local _win_label _win_title _win_avg _win_spark_hours _win_tier
        local _eta_rate _eta_secs _before_reset
        cu_window_config "$win" || continue
        local pct reset
        pct=$(cu_usage_field "$win" utilization "$data")
        reset=$(cu_usage_field "$win" resets_at "$data")
        [ -z "$pct" ] && continue

        printf "%s%s%s\n" "$(cu_color "$CU_FG")" "$_win_title" "$(cu_reset)"
        printf "  %s  %s" "$(cu_progress_bar "$pct" 20)" "$(cu_fmt_pct "$pct")"
        _cu_dashboard_reset "$win" "$reset"

        cu_window_eta "$win" "$_win_avg" "$pct" "$reset"
        printf "\n  +%s%%/h" "$(cu_fmt_rate "$_eta_rate")"
        if [ "${_eta_secs:-0}" -gt 0 ] 2>/dev/null; then
            printf " | ~%s to cap" "$(cu_fmt_eta "$win" "$_eta_secs")"
            [ "$_before_reset" = "1" ] && printf " | %sBEFORE RESET%s" "$(cu_color "$CU_COLOR_WARN")" "$(cu_reset)"
        else
            printf " | no cap before reset"
        fi

        local mode="braille" spark
        [ "$CU_SPARKLINE_TYPE" = "block" ] && mode="block"
        spark=$(cu_sparkline_from_history "$win" "$_win_spark_hours" 20 "$mode" "$_win_tier" 2>/dev/null || true)
        if [ -n "$spark" ]; then
            printf "\n  %sBurn rate:%s %s%s%s" \
                "$(cu_color "$CU_DIM")" "$(cu_reset)" \
                "$(cu_color "$CU_COLOR_SPARKLINE")" "$spark" "$(cu_reset)"
        fi
        printf "\n\n"
    done
}

# "    resets in 1h 20m" (5h) or "    resets Fri 9am (1d 18h)" (7d)
_cu_dashboard_reset() {
    local win="$1" reset="$2" secs
    [ -n "$reset" ] || return 0
    secs=$(cu_secs_until_reset "$reset")
    printf "    %s" "$(cu_color "$CU_COLOR_RESET")"
    if [ "$win" = "seven_day" ]; then
        printf "resets %s" "$(cu_fmt_reset_date "$reset")"
        [ "$secs" -gt 0 ] 2>/dev/null && printf " (%s)" "$(cu_fmt_duration "$secs")"
    elif [ "${secs:-0}" -gt 0 ] 2>/dev/null; then
        printf "resets in %s" "$(cu_fmt_duration "$secs")"
    else
        printf "resets now"
    fi
    printf "%s" "$(cu_reset)"
}
