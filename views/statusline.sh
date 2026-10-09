#!/usr/bin/env bash
# statusline.sh - Claude Code statusline (single-line or multi-line)
#
# Claude Code runs the statusline command after each message and passes
# session JSON on stdin (workspace.current_dir, and since v2.1.80
# rate_limits). Output layout:
#
#   single:    <header> | 5h: <modules> | 7d: <modules> | pace: ...
#   multiline: <header>
#              5h <modules, column-aligned>
#              7d <modules, column-aligned>
#              pa <pace bar>

cu_view_statusline() {
    if [ -t 0 ]; then
        echo "Error: statusline expects JSON on stdin" >&2
        return 1
    fi
    local input
    input=$(cat)
    cu_log "statusline: stdin ${#input} bytes"

    local cwd cwd_basename git_branch="" task_desc task_progress
    cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
    cwd_basename=$(basename "${cwd:-.}")
    [ -n "$cwd" ] && git_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
    cu_task_info
    cu_log "statusline: cwd=$cwd branch=$git_branch task=$task_desc progress=$task_progress"

    local data="" cache_error="" _cache_stale=""
    local five_pct="" seven_pct="" five_reset="" seven_reset=""
    if cu_limits_disabled; then
        cu_log "statusline: usage limits disabled (custom endpoint or CU_NO_LIMITS)"
    else
        _cu_statusline_load_usage "$input"
    fi

    cu_update_check_bg

    if [ "${CU_OPT_MULTILINE:-}" = "1" ]; then
        _cu_statusline_multiline
    else
        _cu_statusline_single
    fi
}

# Refresh usage data and load it into the caller's variables.
#
# Prefer the rate_limits that Claude Code v2.1.80+ pipes on stdin: the
# /api/oauth/usage endpoint is aggressively rate-limited and hard to recover
# once tripped (anthropics/claude-code#31637). Call the API only when stdin
# has no rate_limits (older Claude Code, or the first render of a session).
_cu_statusline_load_usage() {
    local input="$1" fetched="" piped
    piped=$(cu_extract_piped_usage "$input" 2>/dev/null || true)
    if [ -n "$piped" ]; then
        cu_log "statusline: using rate_limits from stdin"
        cu_write_cache "$piped"
        cu_history_record "$piped"
        fetched=1
    elif [ "${CU_OPT_NO_FETCH:-}" != "1" ]; then
        if cu_fetch_and_record; then
            fetched=1
        else
            cu_log "statusline: fetch failed, using cached data"
        fi
    fi

    data=$(cu_read_cache)
    [ -z "$data" ] && { cu_log "statusline: no cached data available"; return 0; }

    # Data older than twice the cache TTL means refreshes keep failing.
    if [ -z "$fetched" ] && [ "$(cu_cache_age)" -gt $((CU_CACHE_MAX_AGE * 2)) ]; then
        _cache_stale=1
    fi
    cache_error=$(echo "$data" | jq -r '._error // empty' 2>/dev/null)
    five_pct=$(cu_get_five_hour_pct "$data")
    seven_pct=$(cu_get_seven_day_pct "$data")
    five_reset=$(cu_get_five_hour_reset "$data")
    seven_reset=$(cu_get_seven_day_reset "$data")
    cu_log "statusline: five_pct=$five_pct seven_pct=$seven_pct"
}

# "(stale 1h 9m, retry 10m)"
_cu_stale_detail() {
    local parts remaining
    parts="stale $(cu_fmt_duration "$(cu_cache_age)")"
    remaining=$(cu_backoff_remaining)
    [ "$remaining" -gt 0 ] && parts+=", retry $(cu_fmt_duration "$remaining")"
    printf '%s(%s)%s' "$(cu_color "$CU_DIM")" "$parts" "$(cu_reset)"
}

# Header from CU_HEADER_MODULES: dir, branch, task (label and progress).
_cu_statusline_header() {
    local mod out=""
    for mod in $(cu_words "$CU_HEADER_MODULES"); do
        local part=""
        case "$mod" in
            dir)    part="$(cu_color "$CU_COLOR_DIR")${cwd_basename}$(cu_reset)" ;;
            branch) [ -n "$git_branch" ] && part="$(cu_color "$CU_COLOR_BRANCH") ${git_branch}$(cu_reset)" ;;
            task)
                [ -n "$task_desc" ] && part="$(cu_color "$CU_COLOR_LABEL")· ${task_desc}$(cu_reset)"
                [ -n "$task_progress" ] && part+="${part:+ }$(cu_color "$CU_DIM")(${task_progress})$(cu_reset)"
                ;;
        esac
        [ -n "$part" ] && out+="${out:+ }$part"
    done
    printf '%s' "$out"
}

# Load window WIN (five_hour|seven_day) into _win_* and its projection into
# _eta_*. Returns 1 for an unknown window or one without data.
_cu_load_window() {
    _win_field="$1"
    cu_window_config "$_win_field" || return 1
    case "$_win_field" in
        five_hour) _win_pct="$five_pct";  _win_reset="$five_reset" ;;
        seven_day) _win_pct="$seven_pct"; _win_reset="$seven_reset" ;;
    esac
    [ -n "$_win_pct" ] || return 1
    cu_window_eta "$_win_field" "$_win_avg" "$_win_pct" "$_win_reset"
}

# --- Modules ---------------------------------------------------------------
# Each renders one piece of the loaded window; empty output hides it.

_cu_mod_bar() {
    cu_progress_bar "$_win_pct" "$CU_BAR_WIDTH"
}

_cu_mod_pct() {
    cu_fmt_pct "$_win_pct"
}

_cu_mod_sparkline() {
    local mode="braille" spark
    [ "$CU_SPARKLINE_TYPE" = "block" ] && mode="block"
    spark=$(cu_sparkline_from_history "$_win_field" "$_win_spark_hours" "$CU_SPARKLINE_WIDTH" "$mode" "$_win_tier" 2>/dev/null || true)
    [ -n "$spark" ] && printf '%s%s%s' "$(cu_color "$CU_COLOR_SPARKLINE")" "$spark" "$(cu_reset)"
    return 0
}

_cu_mod_rate() {
    [ -n "$_eta_rate" ] || return 0
    local color="$CU_COLOR_RATE"
    [ "$_before_reset" = "1" ] && color="$CU_COLOR_WARN"
    printf '%s%s%s' "$(cu_color "$color")" "$(cu_fmt_rate_per_window "$_eta_rate" "$_win_avg")" "$(cu_reset)"
}

# Hidden without a projection; the reset module still shows.
_cu_mod_eta() {
    [ "${_eta_secs:-0}" -gt 0 ] 2>/dev/null || return 0
    local eta_str color="$CU_COLOR_ETA"
    eta_str=$(cu_fmt_eta "$_win_field" "$_eta_secs")
    [ -n "$eta_str" ] || return 0
    [ -z "$color" ] && color=$(cu_eta_color "$_eta_secs" "$_win_reset")
    printf '%s~%s%s' "$(cu_color "$color")" "$eta_str" "$(cu_reset)"
}

_cu_mod_reset() {
    [ -n "$_win_reset" ] || return 0
    local reset_str secs
    if [ "$_win_field" = "five_hour" ]; then
        secs=$(cu_secs_until_reset "$_win_reset")
        reset_str="now"
        [ "${secs:-0}" -gt 0 ] 2>/dev/null && reset_str=$(cu_fmt_duration "$secs")
    else
        reset_str=$(cu_fmt_reset_date "$_win_reset")
    fi
    [ -n "$reset_str" ] || return 0
    printf '%s↻%s %s%s%s' \
        "$(cu_color "$CU_COLOR_RESET_ICON")" "$(cu_reset)" \
        "$(cu_color "$CU_COLOR_RESET")" "$reset_str" "$(cu_reset)"
}

# Render module MOD of the loaded window. Unknown modules print nothing.
_cu_render_module() {
    case "$1" in
        bar|pct|sparkline|rate|eta|reset) "_cu_mod_$1" ;;
    esac
}

# --- Single-line layout ----------------------------------------------------

_cu_statusline_single() {
    local modules="${CU_MODULES:-$CU_DEFAULT_MODULES_SINGLE}"
    local sep
    sep="$(cu_color "$CU_DIM")|$(cu_reset)"

    local -a segments=()
    local header
    header=$(_cu_statusline_header)
    [ -n "$header" ] && segments+=("$header")

    if [ -n "$cache_error" ]; then
        segments+=("$(cu_color "$CU_DIM")rate limited, retrying soon$(cu_reset)")
    elif [ -n "$data" ]; then
        local win
        for win in $(cu_words "$CU_WINDOWS"); do
            local _win_field _win_pct _win_reset _win_avg _win_label _win_title _win_spark_hours _win_tier
            local _eta_rate _eta_secs _before_reset
            _cu_load_window "$win" || continue
            local part mod out
            part="$(cu_color "$CU_COLOR_LABEL")${_win_label}:$(cu_reset)"
            for mod in $(cu_words "$modules"); do
                [ "$mod" = "bar" ] && continue  # bar is multiline-only
                out=$(_cu_render_module "$mod")
                [ -n "$out" ] && part+=" $out"
            done
            segments+=("$part")
        done
    fi

    local line="" i
    for i in "${!segments[@]}"; do
        if [ "$i" -eq 0 ]; then
            line="${segments[$i]}"
        elif [ "$i" -eq 1 ] && [ -n "$header" ] && [ -n "$cache_error" ]; then
            line+=" ${segments[$i]}"
        else
            line+=" $sep ${segments[$i]}"
        fi
    done
    printf '%s' "$line"

    [ "$_cache_stale" = "1" ] && printf ' %s' "$(_cu_stale_detail)"
    cu_pace_render_inline "$seven_pct" "$seven_reset"
    local update_msg
    update_msg=$(cu_update_message)
    [ -n "$update_msg" ] && printf ' %s' "$update_msg"
    return 0
}

# --- Multi-line layout -----------------------------------------------------

_cu_statusline_multiline() {
    local modules="${CU_MODULES:-$CU_DEFAULT_MODULES_MULTI}"
    local nl=""  # newline before each row, except a first row without header

    local header
    header=$(_cu_statusline_header)
    if [ -n "$header" ]; then
        printf '%s' "$header"
        nl=$'\n'
    fi

    [ -n "$data" ] || return 0
    if [ -n "$cache_error" ]; then
        local retry_at detail="retrying soon" secs_left
        retry_at=$(echo "$data" | jq -r '._retry_at // empty' 2>/dev/null)
        if [ -n "$retry_at" ]; then
            secs_left=$(( retry_at - $(cu_now) ))
            [ "$secs_left" -gt 0 ] && detail="retry in $(cu_fmt_duration "$secs_left")"
        fi
        printf '%s%sAPI rate limited, %s%s' "$nl" "$(cu_color "$CU_DIM")" "$detail" "$(cu_reset)"
        return 0
    fi

    local -a mods=() labels=() cells=() widths=() col_max=()
    local mod win
    for mod in $(cu_words "$modules"); do mods+=("$mod"); col_max+=(0); done
    local num_mods=${#mods[@]}

    # Pass 1: render every cell and measure the widest one per column.
    # cells/widths are flat arrays indexed by row * num_mods + column.
    local row=0 mi idx out w
    for win in $(cu_words "$CU_WINDOWS"); do
        local _win_field _win_pct _win_reset _win_avg _win_label _win_title _win_spark_hours _win_tier
        local _eta_rate _eta_secs _before_reset
        cu_window_config "$win" || continue
        labels[row]="$_win_label"
        local have_data=1
        _cu_load_window "$win" || have_data=0
        for (( mi = 0; mi < num_mods; mi++ )); do
            idx=$(( row * num_mods + mi ))
            out=""
            [ "$have_data" = "1" ] && out=$(_cu_render_module "${mods[$mi]}")
            w=0
            [ -n "$out" ] && w=$(cu_visible_len "$out")
            cells[idx]="$out"
            widths[idx]=$w
            [ "$w" -gt "${col_max[mi]}" ] && col_max[mi]=$w
        done
        row=$((row + 1))
    done

    # The last column that has any output is not padded (no trailing spaces).
    local last_col=-1
    for (( mi = 0; mi < num_mods; mi++ )); do
        [ "${col_max[mi]}" -gt 0 ] && last_col=$mi
    done

    # Pass 2: print rows with columns padded to the widest cell.
    local r
    for (( r = 0; r < row; r++ )); do
        printf '%s%s%s%s' "$nl" "$(cu_color "$CU_COLOR_LABEL")" "${labels[$r]}" "$(cu_reset)"
        nl=$'\n'
        for (( mi = 0; mi < num_mods; mi++ )); do
            [ "${col_max[mi]}" -eq 0 ] && continue
            idx=$(( r * num_mods + mi ))
            printf ' %s' "${cells[$idx]}"
            [ "$mi" -lt "$last_col" ] && printf '%*s' $(( col_max[mi] - widths[idx] )) ""
        done
    done

    [ "$_cache_stale" = "1" ] && printf ' %s' "$(_cu_stale_detail)"
    cu_pace_render_multiline "$seven_pct" "$seven_reset"
    local update_msg
    update_msg=$(cu_update_message)
    [ -n "$update_msg" ] && printf '\n%s' "$update_msg"
    return 0
}
