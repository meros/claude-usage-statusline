#!/usr/bin/env bash
# statusline.sh - Claude Code single-line view

cu_view_statusline() {
    local input
    input=$(cat)

    local cwd cwd_basename git_branch
    cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
    cwd_basename=$(basename "${cwd:-.}")
    git_branch=$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null || true)

    # Fetch + record history
    if [ "${CU_OPT_NO_FETCH:-}" != "1" ]; then
        cu_fetch
        local cache_data
        cache_data=$(cu_read_cache)
        [ -n "$cache_data" ] && cu_history_record "$cache_data"
    fi

    local data
    data=$(cu_read_cache)

    # Build directory + git branch section
    local dir_section
    if [ -n "$git_branch" ]; then
        dir_section="$(cu_color "$CU_AQUA")${cwd_basename}$(cu_reset) $(cu_color "$CU_GREEN") ${git_branch}$(cu_reset)"
    else
        dir_section="$(cu_color "$CU_AQUA")${cwd_basename}$(cu_reset)"
    fi

    # Build usage section
    local usage_section=""
    if [ -n "$data" ]; then
        local five_pct seven_pct reset_iso
        five_pct=$(cu_get_five_hour_pct "$data")
        seven_pct=$(cu_get_seven_day_pct "$data")
        reset_iso=$(cu_get_seven_day_reset "$data")

        local parts=()
        if [ -n "$five_pct" ]; then
            local five_int="${five_pct%.*}"
            local five_color
            five_color=$(cu_pct_color "$five_int")
            parts+=("$(printf "5h: %s%d%%%s" "$(cu_color "$five_color")" "$five_int" "$(cu_reset)")")
        fi

        if [ -n "$seven_pct" ]; then
            local seven_int="${seven_pct%.*}"
            local seven_color
            seven_color=$(cu_pct_color "$seven_int")
            local reset_part=""
            if [ -n "$reset_iso" ]; then
                local reset_date
                reset_date=$(cu_fmt_reset_date "$reset_iso")
                [ -n "$reset_date" ] && reset_part=" resets $reset_date"
            fi
            parts+=("$(printf "7d: %s%d%%%s%s" "$(cu_color "$seven_color")" "$seven_int" "$(cu_reset)" "$reset_part")")
        fi

        # ETA projection
        local eta_info
        eta_info=$(cu_eta_projection "seven_day" 48 2>/dev/null)
        if [ -n "$eta_info" ]; then
            local eta_secs before_reset
            eval "$eta_info" 2>/dev/null
            if [ -n "$eta_secs" ] && [ "${eta_secs:-0}" -gt 0 ] 2>/dev/null; then
                local eta_str
                eta_str=$(cu_fmt_duration "$eta_secs")
                local eta_part="~${eta_str} to cap"
                [ "${before_reset:-}" = "1" ] && eta_part="$(cu_color "$CU_RED")${eta_part}$(cu_reset)"
                parts+=("$eta_part")
            fi
        fi

        if [ ${#parts[@]} -gt 0 ]; then
            local IFS_OLD="$IFS"
            usage_section=" $(cu_color "$CU_DIM")|$(cu_reset) "
            local first=1
            for part in "${parts[@]}"; do
                [ "$first" = "1" ] && first=0 || usage_section+=" $(cu_color "$CU_DIM")|$(cu_reset) "
                usage_section+="$part"
            done
        fi

        # Sparkline from history
        local spark
        spark=$(cu_sparkline_from_history "seven_day" 168 8 2>/dev/null)
        if [ -n "$spark" ]; then
            usage_section+=" $(cu_color "$CU_DIM")${spark}$(cu_reset)"
        fi
    fi

    printf "%s%s" "$dir_section" "$usage_section"
}
