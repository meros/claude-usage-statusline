#!/usr/bin/env bash
# cli.sh - Flag parsing, subcommands and dispatch for bin/claude-usage

CU_OPT_NO_FETCH=""
CU_OPT_WIDTH=""
CU_OPT_HOURS=""
CU_OPT_BRAILLE=""
CU_OPT_MULTILINE=""
CU_OPT_TIER=""
CU_OPT_STATUSLINE_FLAGS=()  # display flags, kept for install-hook

# Fail with "Error: FLAG requires VALUE" when the flag has no argument.
_cu_need_arg() {
    [ "$1" -ge 2 ] && return 0
    echo "Error: $2 requires $3" >&2
    return 1
}

cu_parse_flags() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-color)
                CU_NO_COLOR=1
                ;;
            --no-fetch)
                CU_OPT_NO_FETCH=1
                ;;
            --tier)
                _cu_need_arg $# "$1" "a value (short or long)" || return 1
                shift; CU_OPT_TIER="$1"
                ;;
            --data-dir)
                _cu_need_arg $# "$1" "a path" || return 1
                shift; CU_DATA_DIR="$1"
                cu_set_paths
                ;;
            --cache-dir)
                _cu_need_arg $# "$1" "a path" || return 1
                shift; CU_CACHE_DIR="$1"
                cu_set_paths
                ;;
            --width)
                _cu_need_arg $# "$1" "a number" || return 1
                shift; CU_OPT_WIDTH="$1"
                ;;
            --hours)
                _cu_need_arg $# "$1" "a number" || return 1
                shift; CU_OPT_HOURS="$1"
                ;;
            --braille)
                CU_OPT_BRAILLE=1
                ;;
            --multiline)
                CU_OPT_MULTILINE=1
                CU_OPT_STATUSLINE_FLAGS+=("$1")
                ;;
            --eta-windows|--windows)
                _cu_need_arg $# "$1" "a value" || return 1
                CU_OPT_STATUSLINE_FLAGS+=(--windows "$2")
                shift; CU_WINDOWS="$1"
                ;;
            --modules)
                _cu_need_arg $# "$1" "a value" || return 1
                CU_OPT_STATUSLINE_FLAGS+=("$1" "$2")
                shift; CU_MODULES="$1"
                ;;
            --sparkline-type)
                _cu_need_arg $# "$1" "a value (braille or block)" || return 1
                CU_OPT_STATUSLINE_FLAGS+=("$1" "$2")
                shift; CU_SPARKLINE_TYPE="$1"
                ;;
            --bar-width)
                _cu_need_arg $# "$1" "a number" || return 1
                CU_OPT_STATUSLINE_FLAGS+=("$1" "$2")
                shift; CU_BAR_WIDTH="$1"
                ;;
            *)
                echo "Unknown flag: $1" >&2
                return 1
                ;;
        esac
        shift
    done
}

cmd_show() {
    cu_parse_flags "$@" || return 1
    cu_view_dashboard
}

cmd_statusline() {
    cu_parse_flags "$@" || return 1
    cu_view_statusline
}

cmd_sparkline() {
    cu_parse_flags "$@" || return 1
    local tier="${CU_OPT_TIER:-long}" field="seven_day" mode=""
    [ "$tier" = "short" ] && field="five_hour"
    [ "$CU_OPT_BRAILLE" = "1" ] && mode="braille"
    cu_fetch_and_record || true
    cu_sparkline_from_history "$field" "${CU_OPT_HOURS:-168}" "${CU_OPT_WIDTH:-40}" "$mode" "$tier"
    echo
}

cmd_eta() {
    cu_parse_flags "$@" || return 1
    cu_fetch_and_record || true
    local data win any_output=""
    data=$(cu_read_cache)
    for win in $(cu_words "$CU_WINDOWS"); do
        local _win_label _win_title _win_avg _win_spark_hours _win_tier
        local _eta_rate _eta_secs _before_reset
        cu_window_config "$win" || continue
        cu_window_eta "$win" "$_win_avg" \
            "$(cu_usage_field "$win" utilization "$data")" "$(cu_usage_field "$win" resets_at "$data")"
        [ "${_eta_secs:-0}" -gt 0 ] 2>/dev/null || [ "$_eta_rate" != "0" ] || continue

        [ -n "$any_output" ] && printf "\n"
        printf "%s\n" "$_win_title"
        printf "  Rate: +%s%%/hour\n" "$(cu_fmt_rate "$_eta_rate")"
        if [ "${_eta_secs:-0}" -gt 0 ] 2>/dev/null; then
            printf "  ETA to 100%%: ~%s (%s)\n" "$(cu_fmt_duration "$_eta_secs")" "$(cu_fmt_eta_date "$_eta_secs")"
        else
            printf "  ETA to 100%%: not before reset\n"
        fi
        [ "$_before_reset" = "1" ] && printf "  %sWARNING: Projected to hit limit BEFORE reset%s\n" "$(cu_color "$CU_RED")" "$(cu_reset)"
        any_output=1
    done
    [ -z "$any_output" ] && echo "Insufficient history data for projection."
    return 0
}

cmd_fetch() {
    cu_parse_flags "$@" || return 1
    echo "Fetching usage data..."
    if ! cu_fetch force; then
        echo "Failed to fetch usage data." >&2
        return 1
    fi
    local data
    data=$(cu_read_cache)
    cu_history_record "$data"
    echo "OK. 5h: $(cu_get_five_hour_pct "$data")% | 7d: $(cu_get_seven_day_pct "$data")%"
    cu_history_prune
}

cmd_history() {
    cu_parse_flags "$@" || return 1
    local file
    case "${CU_OPT_TIER:-}" in
        "")
            if [ ! -f "$CU_HISTORY_SHORT" ] && [ ! -f "$CU_HISTORY_LONG" ]; then
                echo "No history yet. Run 'claude-usage fetch' to start recording." >&2
            else
                cu_history_dump
            fi
            ;;
        short|long)
            file=$(cu_history_file "$CU_OPT_TIER")
            if [ -f "$file" ]; then
                cat "$file"
            else
                echo "No ${CU_OPT_TIER}-tier history yet. Run 'claude-usage fetch' to start recording." >&2
            fi
            ;;
        *)
            echo "Unknown tier: $CU_OPT_TIER (use short or long)" >&2
            return 1
            ;;
    esac
}

cmd_history_view() {
    cu_parse_flags "$@" || return 1
    cu_view_history
}

cmd_debug_template() {
    cu_parse_flags "$@" || return 1
    cu_fetch_and_record || true

    local data util reset_at secs_to_reset
    data=$(cu_read_cache)
    if [ -z "$data" ]; then
        echo "No cached usage data. Run 'claude-usage fetch' first." >&2
        return 1
    fi
    util=$(cu_get_seven_day_pct "$data")
    reset_at=$(cu_get_seven_day_reset "$data")
    if [ -z "$reset_at" ]; then
        echo "No seven_day.resets_at in cache — cannot debug template." >&2
        return 1
    fi
    secs_to_reset=$(cu_secs_until_reset "$reset_at")
    if [ "${secs_to_reset:-0}" -le 0 ]; then
        echo "seven_day reset is at or in the past — nothing to project." >&2
        return 1
    fi
    util="${util%.*}"
    cu_debug_template_seven_day "${util:-0}" "$secs_to_reset"
}

# Path to put in settings.json. Prefer claude-usage on PATH when it is this
# same install (same bin directory): a Nix store path changes on every
# upgrade, the profile link does not.
_cu_install_command() {
    local on_path
    on_path=$(command -v claude-usage 2>/dev/null || true)
    if [ -n "$on_path" ] &&
        [ "$(dirname "$(readlink -f "$on_path")")" = "$(dirname "$(readlink -f "$CU_SELF")")" ]; then
        echo "$on_path"
    else
        echo "$CU_SELF"
    fi
}

cmd_install_hook() {
    cu_parse_flags "$@" || return 1
    local settings_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    local cmd
    cmd="$(_cu_install_command) statusline"
    [ ${#CU_OPT_STATUSLINE_FLAGS[@]} -gt 0 ] && cmd+=" ${CU_OPT_STATUSLINE_FLAGS[*]}"

    mkdir -p "$(dirname "$settings_file")"
    [ -f "$settings_file" ] || echo '{}' > "$settings_file"

    local tmp="${settings_file}.tmp"
    if jq --arg cmd "$cmd" '.statusLine.type = "command" | .statusLine.command = $cmd' "$settings_file" > "$tmp"; then
        mv "$tmp" "$settings_file"
    else
        rm -f "$tmp"
        echo "Failed to update settings (invalid JSON?)" >&2
        return 1
    fi

    echo "Configured Claude Code statusline:"
    echo "  command: $cmd"
    echo "  settings: $settings_file"
}

cmd_help() {
    cat <<'EOF'
claude-usage - Claude plan usage in your statusline, with history and projections

Usage: claude-usage [command] [flags]

Commands:
  show            Full dashboard (default)
  statusline      Claude Code statusline (reads session JSON from stdin)
  sparkline       Sparkline string only
  eta             Burn rate and time to 100% per window
  fetch           Force-fetch from the API and record history
  history         Dump raw JSONL history
  history-view    History tables with sparklines (alias: hv)
  debug-template  Trace the seasonal 7d ETA (alias: dt)
  install-hook    Set the statusline command in ~/.claude/settings.json
                  (display flags such as --multiline are kept in the command)
  help            This text

Flags:
  --no-color             Disable color output
  --no-fetch             Skip the API call, use cached data
  --data-dir PATH        History directory
  --cache-dir PATH       Cache directory
  --width N              Sparkline width (sparkline command)
  --hours N              History window in hours (sparkline, history-view)
  --braille              Braille sparkline (sparkline command)
  --tier T               History tier: short (5-min, 36h) or long (hourly, 1yr)
  --multiline            Multi-line statusline with progress bars
  --windows LIST         Windows to show: five_hour,seven_day
  --modules LIST         Modules: bar,pct,sparkline,rate,eta,reset
  --sparkline-type TYPE  braille (default) or block
  --bar-width N          Progress bar width (default: 10)

Every setting also has a CU_* environment variable. See the README:
https://github.com/meros/claude-usage-statusline#configuration
EOF
}

cu_main() {
    # No command, or only flags: the dashboard.
    local subcommand="show"
    case "${1:-}" in
        ""|--help|-h) [ $# -gt 0 ] && { subcommand="$1"; shift; } ;;
        -*) ;;
        *) subcommand="$1"; shift ;;
    esac

    case "$subcommand" in
        show)              cmd_show "$@" ;;
        statusline)        cmd_statusline "$@" ;;
        sparkline)         cmd_sparkline "$@" ;;
        eta)               cmd_eta "$@" ;;
        fetch)             cmd_fetch "$@" ;;
        history)           cmd_history "$@" ;;
        history-view|hv)   cmd_history_view "$@" ;;
        debug-template|dt) cmd_debug_template "$@" ;;
        install-hook)      cmd_install_hook "$@" ;;
        help|--help|-h)    cmd_help ;;
        *)
            echo "Unknown command: $subcommand" >&2
            cmd_help >&2
            return 1
            ;;
    esac
}
