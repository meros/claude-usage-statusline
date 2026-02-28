#!/usr/bin/env bash
# statusline.sh - Claude Code status view (single-line or multi-line)

cu_view_statusline() {
    local input
    if [ -t 0 ]; then
        echo "Error: statusline expects JSON on stdin" >&2
        return 1
    fi
    input=$(cat)
    cu_log "statusline: stdin ${#input} bytes"

    local cwd cwd_basename git_branch
    cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
    cwd_basename=$(basename "${cwd:-.}")
    git_branch=$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null || true)
    cu_log "statusline: cwd=$cwd branch=$git_branch"

    # Fetch + record history (don't abort on fetch failure under set -e)
    if [ "${CU_OPT_NO_FETCH:-}" != "1" ]; then
        cu_fetch || cu_log "statusline: fetch failed, using cached data"
        local cache_data
        cache_data=$(cu_read_cache)
        [ -n "$cache_data" ] && cu_history_record "$cache_data"
    fi

    local data
    data=$(cu_read_cache)

    # Parse usage data once
    local five_pct="" seven_pct="" five_reset="" seven_reset=""
    if [ -n "$data" ]; then
        five_pct=$(cu_get_five_hour_pct "$data")
        seven_pct=$(cu_get_seven_day_pct "$data")
        five_reset=$(cu_get_five_hour_reset "$data")
        seven_reset=$(cu_get_seven_day_reset "$data")
        cu_log "statusline: five_pct=$five_pct seven_pct=$seven_pct"
    else
        cu_log "statusline: no cached data available"
    fi

    if [ "${CU_OPT_MULTILINE:-}" = "1" ]; then
        cu_log "statusline: rendering multiline"
        _statusline_multiline
    else
        cu_log "statusline: rendering single-line"
        _statusline_single
    fi
}

_statusline_single() {
    # Build directory + git branch section
    local dir_section
    if [ -n "$git_branch" ]; then
        dir_section="$(cu_color "$CU_AQUA")${cwd_basename}$(cu_reset) $(cu_color "$CU_GREEN") ${git_branch}$(cu_reset)"
    else
        dir_section="$(cu_color "$CU_AQUA")${cwd_basename}$(cu_reset)"
    fi

    # Build usage section: group sparkline + ETA with each window
    local usage_section=""
    if [ -n "$data" ]; then
        local parts=()

        # 5-Hour group: pct + sparkline + ETA
        if [ -n "$five_pct" ]; then
            local five_int="${five_pct%.*}"
            local five_color
            five_color=$(cu_pct_color "$five_int")
            local five_part
            five_part=$(printf "5h: %s%d%%%s" "$(cu_color "$five_color")" "$five_int" "$(cu_reset)")

            local spark_short
            spark_short=$(cu_sparkline_from_history "five_hour" 5 8 "braille" 2>/dev/null || true)
            [ -n "$spark_short" ] && five_part+=" $(cu_color "$CU_DIM")${spark_short}$(cu_reset)"

            if [[ " ${CU_ETA_WINDOWS} " == *" five_hour "* ]] || [[ "${CU_ETA_WINDOWS}" == *"five_hour"* ]]; then
                local eta_info
                eta_info=$(cu_eta_projection "five_hour" "${CU_ETA_5H_AVG:-3}" 2>/dev/null || true)
                if [ -n "$eta_info" ]; then
                    local eta_rate eta_hours eta_secs before_reset
                    read -r eta_rate eta_hours eta_secs before_reset <<< "$eta_info"
                    if [ -n "${eta_secs:-}" ] && [ "${eta_secs:-0}" -gt 0 ] 2>/dev/null; then
                        local eta_str
                        eta_str=$(cu_fmt_duration "$eta_secs")
                        local eta_part="~${eta_str}"
                        if [ "${before_reset:-}" = "1" ]; then
                            five_part+=" $(cu_color "$CU_RED")${eta_part}$(cu_reset)"
                        else
                            five_part+=" ${eta_part}"
                        fi
                    fi
                fi
            fi
            parts+=("$five_part")
        fi

        # 7-Day group: pct + sparkline + ETA + reset
        if [ -n "$seven_pct" ]; then
            local seven_int="${seven_pct%.*}"
            local seven_color
            seven_color=$(cu_pct_color "$seven_int")
            local seven_part
            seven_part=$(printf "7d: %s%d%%%s" "$(cu_color "$seven_color")" "$seven_int" "$(cu_reset)")

            local spark_long
            spark_long=$(cu_sparkline_from_history "seven_day" 168 8 "braille" 2>/dev/null || true)

            [ -n "$spark_long" ] && seven_part+=" $(cu_color "$CU_DIM")${spark_long}$(cu_reset)"

            if [[ " ${CU_ETA_WINDOWS} " == *" seven_day "* ]] || [[ "${CU_ETA_WINDOWS}" == *"seven_day"* ]]; then
                local eta_info
                eta_info=$(cu_eta_projection "seven_day" "${CU_ETA_7D_AVG:-24}" 2>/dev/null || true)
                if [ -n "$eta_info" ]; then
                    local eta_rate eta_hours eta_secs before_reset
                    read -r eta_rate eta_hours eta_secs before_reset <<< "$eta_info"
                    if [ -n "${eta_secs:-}" ] && [ "${eta_secs:-0}" -gt 0 ] 2>/dev/null; then
                        local eta_str
                        eta_str=$(cu_fmt_duration "$eta_secs")
                        local eta_part="~${eta_str}"
                        if [ "${before_reset:-}" = "1" ]; then
                            seven_part+=" $(cu_color "$CU_RED")${eta_part}$(cu_reset)"
                        else
                            seven_part+=" ${eta_part}"
                        fi
                    fi
                fi
            fi

            if [ -n "$seven_reset" ]; then
                local reset_date
                reset_date=$(cu_fmt_reset_date "$seven_reset")
                [ -n "$reset_date" ] && seven_part+=" resets $reset_date"
            fi
            parts+=("$seven_part")
        fi

        if [ ${#parts[@]} -gt 0 ]; then
            usage_section=" $(cu_color "$CU_DIM")|$(cu_reset) "
            local first=1
            for part in "${parts[@]}"; do
                [ "$first" = "1" ] && first=0 || usage_section+=" $(cu_color "$CU_DIM")|$(cu_reset) "
                usage_section+="$part"
            done
        fi
    fi

    printf "%s%s" "$dir_section" "$usage_section"
}

_statusline_multiline() {
    # Line 1: directory + branch
    if [ -n "$git_branch" ]; then
        printf "%s%s%s %s %s%s" \
            "$(cu_color "$CU_AQUA")" "$cwd_basename" "$(cu_reset)" \
            "$(cu_color "$CU_GREEN")" "$git_branch" "$(cu_reset)"
    else
        printf "%s%s%s" "$(cu_color "$CU_AQUA")" "$cwd_basename" "$(cu_reset)"
    fi

    [ -z "$data" ] && return

    local five_int="${five_pct%.*}"
    local seven_int="${seven_pct%.*}"
    five_int="${five_int:-0}"
    seven_int="${seven_int:-0}"

    # Line 2: 5h group — bar + pct + sparkline + ETA + reset
    if [ -n "$five_pct" ]; then
        printf "\n"
        printf "%s5h%s %s %s" \
            "$(cu_color "$CU_DIM")" "$(cu_reset)" \
            "$(cu_progress_bar "$five_int" 10)" \
            "$(cu_fmt_pct "$five_pct")"

        local spark_short
        spark_short=$(cu_sparkline_from_history "five_hour" 5 8 "braille" 2>/dev/null || true)
        [ -n "$spark_short" ] && printf " %s%s%s" "$(cu_color "$CU_DIM")" "$spark_short" "$(cu_reset)"

        if [[ "${CU_ETA_WINDOWS}" == *"five_hour"* ]]; then
            local eta_info
            eta_info=$(cu_eta_projection "five_hour" "${CU_ETA_5H_AVG:-3}" 2>/dev/null || true)
            if [ -n "$eta_info" ]; then
                local eta_rate eta_hours eta_secs before_reset
                read -r eta_rate eta_hours eta_secs before_reset <<< "$eta_info"
                if [ -n "${eta_secs:-}" ] && [ "${eta_secs:-0}" -gt 0 ] 2>/dev/null; then
                    local eta_str
                    eta_str=$(cu_fmt_duration "$eta_secs")
                    if [ "${before_reset:-}" = "1" ]; then
                        printf " %s~%s%s" "$(cu_color "$CU_RED")" "$eta_str" "$(cu_reset)"
                    else
                        printf " %s~%s%s" "$(cu_color "$CU_DIM")" "$eta_str" "$(cu_reset)"
                    fi
                fi
            fi
        fi

        if [ -n "$five_reset" ]; then
            local secs
            secs=$(cu_secs_until_reset "$five_reset")
            [ "${secs:-0}" -gt 0 ] 2>/dev/null && printf " %s↻%s%s" "$(cu_color "$CU_DIM")" "$(cu_fmt_duration "$secs")" "$(cu_reset)"
        fi
    fi

    # Line 3: 7d group — bar + pct + sparkline + ETA + reset
    if [ -n "$seven_pct" ]; then
        printf "\n"
        printf "%s7d%s %s %s" \
            "$(cu_color "$CU_DIM")" "$(cu_reset)" \
            "$(cu_progress_bar "$seven_int" 10)" \
            "$(cu_fmt_pct "$seven_pct")"

        local spark_long
        spark_long=$(cu_sparkline_from_history "seven_day" 168 8 "braille" 2>/dev/null || true)
        [ -n "$spark_long" ] && printf " %s%s%s" "$(cu_color "$CU_DIM")" "$spark_long" "$(cu_reset)"

        if [[ "${CU_ETA_WINDOWS}" == *"seven_day"* ]]; then
            local eta_info
            eta_info=$(cu_eta_projection "seven_day" "${CU_ETA_7D_AVG:-24}" 2>/dev/null || true)
            if [ -n "$eta_info" ]; then
                local eta_rate eta_hours eta_secs before_reset
                read -r eta_rate eta_hours eta_secs before_reset <<< "$eta_info"
                if [ -n "${eta_secs:-}" ] && [ "${eta_secs:-0}" -gt 0 ] 2>/dev/null; then
                    local eta_str
                    eta_str=$(cu_fmt_duration "$eta_secs")
                    if [ "${before_reset:-}" = "1" ]; then
                        printf " %s~%s%s" "$(cu_color "$CU_RED")" "$eta_str" "$(cu_reset)"
                    else
                        printf " %s~%s%s" "$(cu_color "$CU_DIM")" "$eta_str" "$(cu_reset)"
                    fi
                fi
            fi
        fi

        if [ -n "$seven_reset" ]; then
            local reset_date
            reset_date=$(cu_fmt_reset_date "$seven_reset")
            [ -n "$reset_date" ] && printf " %s↻%s%s" "$(cu_color "$CU_DIM")" "$reset_date" "$(cu_reset)"
        fi
    fi
}
