#!/usr/bin/env bash
# config.sh - User settings (CU_* environment variables) and window definitions
#
# Every setting has a default here. CLI flags in cli.sh override them.

# --- What to show --------------------------------------------------------

# CU_ETA_WINDOWS is the old name of CU_WINDOWS; still honored.
CU_WINDOWS="${CU_WINDOWS:-${CU_ETA_WINDOWS:-five_hour,seven_day}}"
CU_MODULES="${CU_MODULES:-}"  # empty = default list for the layout
CU_DEFAULT_MODULES_SINGLE="pct,sparkline,rate,eta,reset"
CU_DEFAULT_MODULES_MULTI="bar,pct,sparkline,rate,eta,reset"
CU_HEADER_MODULES="${CU_HEADER_MODULES-dir,branch,task}"

# --- Look ----------------------------------------------------------------

CU_SPARKLINE_TYPE="${CU_SPARKLINE_TYPE:-braille}"
CU_SPARKLINE_WIDTH="${CU_SPARKLINE_WIDTH:-16}"
CU_BAR_WIDTH="${CU_BAR_WIDTH:-10}"
CU_PCT_WARN="${CU_PCT_WARN:-50}"
CU_PCT_CRIT="${CU_PCT_CRIT:-80}"

CU_COLOR_SPARKLINE="${CU_COLOR_SPARKLINE:-${CU_PURPLE}}"
CU_COLOR_RATE="${CU_COLOR_RATE:-${CU_ORANGE}}"
CU_COLOR_ETA="${CU_COLOR_ETA:-}"  # empty = color by margin to the reset
CU_COLOR_RESET="${CU_COLOR_RESET:-${CU_DIM}}"
CU_COLOR_RESET_ICON="${CU_COLOR_RESET_ICON:-${CU_PURPLE}}"
CU_COLOR_LABEL="${CU_COLOR_LABEL:-${CU_DIM}}"
CU_COLOR_DIR="${CU_COLOR_DIR:-${CU_AQUA}}"
CU_COLOR_BRANCH="${CU_COLOR_BRANCH:-${CU_GREEN}}"
CU_COLOR_WARN="${CU_COLOR_WARN:-${CU_RED}}"

# --- Projection ----------------------------------------------------------

CU_ETA_5H_AVG="${CU_ETA_5H_AVG:-1}"
CU_ETA_7D_AVG="${CU_ETA_7D_AVG:-24}"

# --- Data source ---------------------------------------------------------

CU_CACHE_MAX_AGE="${CU_CACHE_MAX_AGE:-300}"

# --- Update notice -------------------------------------------------------

CU_UPDATE_CHECK="${CU_UPDATE_CHECK:-1}"
CU_UPDATE_TTL="${CU_UPDATE_TTL:-3600}"

# --- Windows -------------------------------------------------------------

# Load the static settings of one limit window into _win_* variables:
#   _win_label        short label ("5h")
#   _win_title        dashboard heading
#   _win_avg          hours of history behind the burn rate
#   _win_spark_hours  hours the sparkline covers
#   _win_tier         history tier the sparkline reads
# Returns 1 for an unknown window name.
cu_window_config() {
    case "$1" in
        five_hour)
            _win_label="5h"
            _win_title="5-Hour Window"
            _win_avg="$CU_ETA_5H_AVG"
            _win_spark_hours=5
            _win_tier="short"
            ;;
        seven_day)
            _win_label="7d"
            _win_title="7-Day Window"
            _win_avg="$CU_ETA_7D_AVG"
            _win_spark_hours=168
            _win_tier="long"
            ;;
        *) return 1 ;;
    esac
}

# Hide Anthropic plan limits when they cannot apply:
#   - CU_NO_LIMITS=1 or CU_HIDE_LIMITS=1
#   - ANTHROPIC_BASE_URL points at a non-Anthropic endpoint (LiteLLM, OpenRouter, ...)
cu_limits_disabled() {
    [ "${CU_NO_LIMITS:-}" = "1" ] && return 0
    [ "${CU_HIDE_LIMITS:-}" = "1" ] && return 0
    if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        case "$ANTHROPIC_BASE_URL" in
            https://api.anthropic.com*|http://api.anthropic.com*) return 1 ;;
            *) return 0 ;;
        esac
    fi
    return 1
}
