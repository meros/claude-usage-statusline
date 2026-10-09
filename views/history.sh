#!/usr/bin/env bash
# history.sh - Formatted history tables (claude-usage history-view)
#
# Recent table: short tier, 5h and 7d columns with the change since the
# previous record. History table: long tier, 7d only. A drop of more than 5
# points shows as ↻ (a reset).

cu_view_history() {
    if [ ! -f "$CU_HISTORY_SHORT" ] && [ ! -f "$CU_HISTORY_LONG" ]; then
        echo "No history yet. Run 'claude-usage fetch' to start recording." >&2
        return 1
    fi

    if [ -f "$CU_HISTORY_SHORT" ]; then
        local short_hours="${CU_OPT_HOURS:-36}"
        printf "%s━━━ Recent (5-min intervals, last %sh) ━━━%s\n" \
            "$(cu_color "$CU_FG")" "$short_hours" "$(cu_reset)"
        _cu_history_table short "$short_hours"
        _cu_history_burn "5h" five_hour "$short_hours" short
    fi

    if [ -f "$CU_HISTORY_LONG" ]; then
        local long_hours="${CU_OPT_HOURS:-168}"
        [ -f "$CU_HISTORY_SHORT" ] && echo ""
        local span="${long_hours}h"
        [ "$long_hours" -ge 48 ] && span="$((long_hours / 24))d"
        printf "%s━━━ History (hourly, last %s) ━━━%s\n" \
            "$(cu_color "$CU_FG")" "$span" "$(cu_reset)"
        _cu_history_table long "$long_hours"
        _cu_history_burn "7d" seven_day "$long_hours" long
    fi
}

_cu_history_burn() {
    local label="$1" field="$2" hours="$3" tier="$4" spark
    echo ""
    spark=$(cu_sparkline_from_history "$field" "$hours" 40 braille "$tier" 2>/dev/null || true)
    printf "%sBurn rate (%s): %s%s%s%s\n" "$(cu_color "$CU_DIM")" "$label" "$(cu_reset)" \
        "$(cu_color "$CU_COLOR_SPARKLINE")" "${spark:-  (no data)}" "$(cu_reset)"
}

# Print STR, then pad it with spaces to WIDTH visible characters.
_cu_pad() {
    printf "%s" "$1"
    local vlen
    vlen=$(cu_visible_len "$1")
    [ "$vlen" -lt "$2" ] && printf "%*s" $(($2 - vlen)) ""
    return 0
}

# Value cell: colored percentage, or a dim "--" without data.
_cu_history_value() {
    if [ -n "$1" ]; then
        cu_fmt_pct "$1"
    else
        printf "%s--%s" "$(cu_color "$CU_DIM")" "$(cu_reset)"
    fi
}

# Change cell from PREV to CUR: "+0.4%", ↻ for a reset, blank without both.
_cu_history_delta() {
    local cur="$1" prev="$2"
    if [ -z "$cur" ] || [ -z "$prev" ]; then
        printf ' '
        return
    fi
    local delta
    delta=$(awk -v c="$cur" -v p="$prev" 'BEGIN { printf "%.1f", c - p }')
    if awk -v d="$delta" 'BEGIN { exit !(d < -5) }'; then
        printf '%s↻%s' "$(cu_color "$CU_COLOR_RESET_ICON")" "$(cu_reset)"
    else
        printf '%s%s%s' "$(cu_color "$CU_AQUA")" "$(awk -v d="$delta" 'BEGIN { printf "%+.1f%%", d }')" "$(cu_reset)"
    fi
}

# Table of TIER for the last HOURS. The short tier has 5h columns too.
_cu_history_table() {
    local tier="$1" hours="$2"
    local dim reset rule="────────"
    dim=$(cu_color "$CU_DIM")
    reset=$(cu_reset)

    if [ "$tier" = "short" ]; then
        printf "%s%-20s  %-8s  %-8s  %-8s  Change%s\n" "$dim" "Time" "5h %" "Δ 5h" "7d %" "$reset"
        printf "%s%-20s  %-8s  %-8s  %-8s  %-6s%s\n" "$dim" "────────────────────" "$rule" "$rule" "$rule" "──────" "$reset"
    else
        printf "%s%-20s  %-8s  Change%s\n" "$dim" "Time" "7d %" "$reset"
        printf "%s%-20s  %-8s  %-6s%s\n" "$dim" "────────────────────" "$rule" "──────" "$reset"
    fi

    local ts five seven prev_five="" prev_seven=""
    while IFS='|' read -r ts five seven; do
        [ -z "$ts" ] && continue
        printf "%-20s  " "$(date -d "@$ts" "+%b %d %H:%M" 2>/dev/null || date -r "$ts" "+%b %d %H:%M" 2>/dev/null)"
        if [ "$tier" = "short" ]; then
            _cu_pad "$(_cu_history_value "$five")" 8
            printf "  "
            _cu_pad "$(_cu_history_delta "$five" "$prev_five")" 8
            printf "  "
            [ -n "$five" ] && prev_five="$five"
        fi
        _cu_pad "$(_cu_history_value "$seven")" 8
        printf "  %s\n" "$(_cu_history_delta "$seven" "$prev_seven")"
        [ -n "$seven" ] && prev_seven="$seven"
    done < <(cu_history_read "$tier" "$hours" |
        jq -r '[.ts, (.five_hour.util // ""), (.seven_day.util // "")] | map(tostring) | join("|")' 2>/dev/null)
}
