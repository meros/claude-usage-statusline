#!/usr/bin/env bash
# statusline.sh - Claude Code status view (single-line or multi-line)

# Default module lists (can be overridden via CU_MODULES env var)
_CU_DEFAULT_MODULES_SINGLE="pct,sparkline,rate,eta,reset"
_CU_DEFAULT_MODULES_MULTI="bar,pct,sparkline,rate,eta,reset"

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
    local five_pct="" seven_pct="" five_reset="" seven_reset="" cache_error=""
    if [ -n "$data" ]; then
        cache_error=$(echo "$data" | jq -r '._error // empty' 2>/dev/null)
        five_pct=$(cu_get_five_hour_pct "$data")
        seven_pct=$(cu_get_seven_day_pct "$data")
        five_reset=$(cu_get_five_hour_reset "$data")
        seven_reset=$(cu_get_seven_day_reset "$data")
        cu_log "statusline: five_pct=$five_pct seven_pct=$seven_pct"
    else
        cu_log "statusline: no cached data available"
    fi

    # Trigger background update check
    cu_update_check_bg

    if [ "${CU_OPT_MULTILINE:-}" = "1" ]; then
        cu_log "statusline: rendering multiline"
        _statusline_multiline
    else
        cu_log "statusline: rendering single-line"
        _statusline_single
    fi
}

# --- Module rendering functions ---
# Each takes: window_field, pct, reset_time, and uses shared _eta_info_* vars

_render_mod_bar() {
    local pct_int="${1:-0}"
    local width="${CU_BAR_WIDTH:-10}"
    printf '%s' "$(cu_progress_bar "$pct_int" "$width")"
}

_render_mod_pct() {
    local pct="${1:-0}"
    cu_fmt_pct "$pct"
}

_render_mod_sparkline() {
    local field="$1"
    local spark_hours spark_tier spark_mode
    case "$field" in
        five_hour) spark_hours=5;   spark_tier="short" ;;
        seven_day) spark_hours=168; spark_tier="long" ;;
        *) return 0 ;;
    esac
    spark_mode="${CU_SPARKLINE_TYPE:-braille}"
    # Normalize: anything not "block" becomes "braille"
    [ "$spark_mode" != "block" ] && spark_mode="braille"
    local spark
    spark=$(cu_sparkline_from_history "$field" "$spark_hours" 16 "$spark_mode" "$spark_tier" 2>/dev/null || true)
    [ -n "$spark" ] && printf '%s%s%s' "$(cu_color "${CU_COLOR_SPARKLINE}")" "$spark" "$(cu_reset)"
    return 0
}

_render_mod_rate() {
    # Uses shared _eta_rate, _eta_secs, _before_reset from _compute_eta
    [ -z "${_eta_rate:-}" ] && return 0
    local avg_window="$1"
    local rate_str
    rate_str=$(cu_fmt_rate_per_window "$_eta_rate" "$avg_window")
    if [ "${_before_reset:-}" = "1" ]; then
        printf '%s%s%s' "$(cu_color "${CU_COLOR_WARN}")" "$rate_str" "$(cu_reset)"
    else
        printf '%s%s%s' "$(cu_color "${CU_COLOR_RATE}")" "$rate_str" "$(cu_reset)"
    fi
}

_render_mod_eta() {
    # Uses shared _eta_secs, _before_reset from _compute_eta
    # Args: field (five_hour|seven_day) — determines duration vs date format
    # When no projection available (rate=0, no data): hide entirely — reset module still shows
    local field="${1:-}"
    [ -z "${_eta_secs:-}" ] && return 0
    [ "${_eta_secs:-0}" -le 0 ] 2>/dev/null && return 0
    local eta_str
    case "$field" in
        seven_day) eta_str=$(cu_fmt_eta_date "$_eta_secs") ;;
        *)         eta_str=$(cu_fmt_duration "$_eta_secs") ;;
    esac
    [ -z "$eta_str" ] && return 0
    local color="${CU_COLOR_ETA}"
    [ "${_before_reset:-}" = "1" ] && color="${CU_COLOR_WARN}"
    printf '%s~%s%s' "$(cu_color "$color")" "$eta_str" "$(cu_reset)"
}

_render_mod_reset() {
    local field="$1" reset_time="$2"
    [ -z "$reset_time" ] && return 0

    local icon="↻"

    local reset_str=""
    case "$field" in
        five_hour)
            local secs
            secs=$(cu_secs_until_reset "$reset_time")
            if [ "${secs:-0}" -gt 0 ] 2>/dev/null; then
                reset_str=$(cu_fmt_duration "$secs")
            else
                reset_str="now"
            fi
            ;;
        seven_day)
            reset_str=$(cu_fmt_reset_date "$reset_time")
            ;;
    esac
    [ -z "$reset_str" ] && return 0
    printf '%s%s%s %s%s%s' \
        "$(cu_color "${CU_COLOR_RESET_ICON}")" "$icon" "$(cu_reset)" \
        "$(cu_color "${CU_COLOR_RESET}")" "$reset_str" "$(cu_reset)"
}

# Compute ETA projection, storing results in shared variables
_compute_eta() {
    local field="$1" avg_window="$2"
    _eta_rate="" _eta_hours="" _eta_secs="" _before_reset=""
    local eta_info
    eta_info=$(cu_eta_projection "$field" "$avg_window" 2>/dev/null || true)
    if [ -n "$eta_info" ]; then
        read -r _eta_rate _eta_hours _eta_secs _before_reset <<< "$eta_info"
    else
        # No projection available — set rate to 0 so rate module still displays
        _eta_rate="0"
    fi
}

# Get window config: field, pct, reset_time, avg_window, label
_window_config() {
    local win="$1"
    case "$win" in
        five_hour)
            _win_field="five_hour"
            _win_pct="$five_pct"
            _win_reset="$five_reset"
            _win_avg="${CU_ETA_5H_AVG:-1}"
            _win_label="5h"
            ;;
        seven_day)
            _win_field="seven_day"
            _win_pct="$seven_pct"
            _win_reset="$seven_reset"
            _win_avg="${CU_ETA_7D_AVG:-24}"
            _win_label="7d"
            ;;
        *) return 1 ;;
    esac
}

# --- Single-line layout ---

_statusline_single() {
    local modules="${CU_MODULES:-${_CU_DEFAULT_MODULES_SINGLE}}"

    # Build directory + git branch section
    local dir_section
    if [ -n "$git_branch" ]; then
        dir_section="$(cu_color "${CU_COLOR_DIR}")${cwd_basename}$(cu_reset) $(cu_color "${CU_COLOR_BRANCH}") ${git_branch}$(cu_reset)"
    else
        dir_section="$(cu_color "${CU_COLOR_DIR}")${cwd_basename}$(cu_reset)"
    fi

    # Build usage section
    local usage_section=""
    if [ -n "$cache_error" ]; then
        usage_section=" $(cu_color "$CU_DIM")rate limited, retrying soon$(cu_reset)"
    elif [ -n "$data" ]; then
        local parts=()
        local _win
        for _win in ${CU_WINDOWS//,/ }; do
            local _win_field _win_pct _win_reset _win_avg _win_label
            _window_config "$_win" || continue
            [ -z "$_win_pct" ] && continue

            local pct_int="${_win_pct%.*}"
            pct_int="${pct_int:-0}"

            # Compute ETA once for this window (shared by rate + eta modules)
            _compute_eta "$_win_field" "$_win_avg"

            # Build this window's part from modules
            local win_part=""
            win_part+="$(cu_color "${CU_COLOR_LABEL}")${_win_label}:$(cu_reset) "

            local _mod first_mod=1
            for _mod in ${modules//,/ }; do
                local mod_out=""
                case "$_mod" in
                    bar) continue ;;  # bar is multiline-only
                    pct)       mod_out=$(_render_mod_pct "$_win_pct") ;;
                    sparkline) mod_out=$(_render_mod_sparkline "$_win_field") ;;
                    rate)      mod_out=$(_render_mod_rate "$_win_avg") ;;
                    eta)       mod_out=$(_render_mod_eta "$_win_field") ;;
                    reset)     mod_out=$(_render_mod_reset "$_win_field" "$_win_reset") ;;
                    *) continue ;;
                esac
                if [ -n "$mod_out" ]; then
                    [ "$first_mod" = "1" ] && first_mod=0 || win_part+=" "
                    win_part+="$mod_out"
                fi
            done
            parts+=("$win_part")
        done

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

    # Update notification (appended at end of line)
    local update_msg
    update_msg=$(cu_update_message)
    [ -n "$update_msg" ] && printf " %s" "$update_msg"
    return 0
}

# --- Multi-line layout ---

_statusline_multiline() {
    local modules="${CU_MODULES:-${_CU_DEFAULT_MODULES_MULTI}}"

    # Line 1: directory + branch
    if [ -n "$git_branch" ]; then
        printf "%s%s%s %s %s%s" \
            "$(cu_color "${CU_COLOR_DIR}")" "$cwd_basename" "$(cu_reset)" \
            "$(cu_color "${CU_COLOR_BRANCH}")" "$git_branch" "$(cu_reset)"
    else
        printf "%s%s%s" "$(cu_color "${CU_COLOR_DIR}")" "$cwd_basename" "$(cu_reset)"
    fi

    if [ -z "$data" ]; then return 0; fi

    if [ -n "$cache_error" ]; then
        local retry_at detail="retrying soon"
        retry_at=$(echo "$data" | jq -r '._retry_at // empty' 2>/dev/null)
        if [ -n "$retry_at" ]; then
            local secs_left=$(( retry_at - $(cu_now) ))
            [ "$secs_left" -gt 0 ] && detail="retry in $(cu_fmt_duration "$secs_left")"
        fi
        printf '\n%sAPI rate limited, %s%s' \
            "$(cu_color "$CU_DIM")" "$detail" "$(cu_reset)"
        return 0
    fi

    # Build module list as array for indexed access
    local mod_list=()
    local _m
    for _m in ${modules//,/ }; do
        mod_list+=("$_m")
    done
    local num_mods=${#mod_list[@]}

    # Collect windows into array
    local win_list=()
    for _m in ${CU_WINDOWS//,/ }; do
        win_list+=("$_m")
    done
    local num_wins=${#win_list[@]}

    # --- Pass 1: render all modules, measure visible widths ---
    # Flat arrays indexed by [win * num_mods + mod]
    local _ml_out=()    # rendered output strings
    local _ml_width=()  # visible widths
    local _ml_max=()    # max width per module column
    local _ml_label=()  # window labels

    local wi mi idx
    for (( mi=0; mi<num_mods; mi++ )); do
        _ml_max[$mi]=0
    done

    for (( wi=0; wi<num_wins; wi++ )); do
        local _win_field _win_pct _win_reset _win_avg _win_label
        _window_config "${win_list[$wi]}" || continue
        _ml_label[$wi]="$_win_label"

        if [ -z "$_win_pct" ]; then
            # No data for this window — fill with empty
            for (( mi=0; mi<num_mods; mi++ )); do
                idx=$(( wi * num_mods + mi ))
                _ml_out[$idx]=""
                _ml_width[$idx]=0
            done
            continue
        fi

        local pct_int="${_win_pct%.*}"
        pct_int="${pct_int:-0}"

        _compute_eta "$_win_field" "$_win_avg"

        for (( mi=0; mi<num_mods; mi++ )); do
            idx=$(( wi * num_mods + mi ))
            local mod_out=""
            case "${mod_list[$mi]}" in
                bar)       mod_out=$(_render_mod_bar "$pct_int") ;;
                pct)       mod_out=$(_render_mod_pct "$_win_pct") ;;
                sparkline) mod_out=$(_render_mod_sparkline "$_win_field") ;;
                rate)      mod_out=$(_render_mod_rate "$_win_avg") ;;
                eta)       mod_out=$(_render_mod_eta "$_win_field") ;;
                reset)     mod_out=$(_render_mod_reset "$_win_field" "$_win_reset") ;;
                *) ;;
            esac
            _ml_out[$idx]="$mod_out"
            local vlen=0
            [ -n "$mod_out" ] && vlen=$(cu_visible_len "$mod_out")
            _ml_width[$idx]=$vlen
            [ "$vlen" -gt "${_ml_max[$mi]}" ] && _ml_max[$mi]=$vlen
        done
    done

    # --- Pass 2: output with column padding ---
    for (( wi=0; wi<num_wins; wi++ )); do
        printf "\n"
        printf "%s%s%s " "$(cu_color "${CU_COLOR_LABEL}")" "${_ml_label[$wi]}" "$(cu_reset)"

        local first_mod=1
        for (( mi=0; mi<num_mods; mi++ )); do
            idx=$(( wi * num_mods + mi ))
            local out="${_ml_out[$idx]}"
            local w="${_ml_width[$idx]}"
            local max_w="${_ml_max[$mi]}"

            # Skip columns where no window produced output
            [ "$max_w" -eq 0 ] && continue

            [ "$first_mod" = "1" ] && first_mod=0 || printf " "

            printf "%s" "$out"

            # Right-pad to align columns (only if not the last visible column)
            local pad=$(( max_w - w ))
            [ "$pad" -gt 0 ] && printf "%*s" "$pad" ""
        done
    done

    # Update notification on its own line
    local update_msg
    update_msg=$(cu_update_message)
    [ -n "$update_msg" ] && printf "\n%s" "$update_msg"
    return 0
}
