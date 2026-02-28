#!/usr/bin/env bash
# util.sh - XDG paths, color constants, date math

# XDG directories
CU_DATA_DIR="${CU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-usage}"
CU_CACHE_DIR="${CU_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-usage}"

# Ensure directories exist
mkdir -p "$CU_DATA_DIR" "$CU_CACHE_DIR"

# Debug logging: CU_DEBUG=1 to enable, CU_LOG_FILE=path to log to file
cu_log() {
    [ "${CU_DEBUG:-}" = "1" ] || return 0
    local msg="[claude-usage] $*"
    if [ -n "${CU_LOG_FILE:-}" ]; then
        echo "$msg" >> "$CU_LOG_FILE"
    else
        echo "$msg" >&2
    fi
}

# Epoch override for deterministic tests
cu_now() {
    if [ -n "${CU_NOW:-}" ]; then
        echo "$CU_NOW"
    else
        date +%s
    fi
}

cu_date() {
    if [ -n "${CU_NOW:-}" ]; then
        date -d "@$CU_NOW" "$@" 2>/dev/null || date -r "$CU_NOW" "$@" 2>/dev/null
    else
        date "$@"
    fi
}

# Color support
CU_NO_COLOR="${NO_COLOR:-}"
[ "${CU_OPT_NO_COLOR:-}" = "1" ] && CU_NO_COLOR=1

cu_color() {
    [ -n "$CU_NO_COLOR" ] && return
    printf '\033[%sm' "$1"
}

cu_reset() {
    [ -n "$CU_NO_COLOR" ] && return
    printf '\033[0m'
}

# Gruvbox-inspired palette
CU_GREEN="38;2;142;192;124"
CU_YELLOW="38;2;250;189;47"
CU_RED="38;2;251;73;52"
CU_AQUA="38;2;131;165;152"
CU_PURPLE="38;2;211;134;155"
CU_ORANGE="38;2;254;128;25"
CU_FG="38;2;235;219;178"
CU_DIM="38;2;146;131;116"

# Color based on percentage threshold
cu_pct_color() {
    local pct="${1%.*}"
    pct="${pct:-0}"
    if [ "$pct" -ge 80 ]; then
        echo "$CU_RED"
    elif [ "$pct" -ge 50 ]; then
        echo "$CU_YELLOW"
    else
        echo "$CU_GREEN"
    fi
}

# Format duration from seconds
cu_fmt_duration() {
    local secs="$1"
    if [ "$secs" -lt 0 ]; then
        echo "now"
        return
    fi
    local days=$((secs / 86400))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then
        printf "%dd %dh" "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then
        printf "%dh %dm" "$hours" "$mins"
    else
        printf "%dm" "$mins"
    fi
}

# Format reset time as human-readable date
cu_fmt_reset_date() {
    local iso="$1"
    [ -z "$iso" ] && return
    date -d "$iso" "+%b %-d" 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%%.*}" "+%b %-d" 2>/dev/null
}

# Time until reset in seconds
cu_secs_until_reset() {
    local iso="$1"
    [ -z "$iso" ] && echo "0" && return
    local reset_epoch
    reset_epoch=$(date -d "$iso" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%%.*}" +%s 2>/dev/null)
    local now
    now=$(cu_now)
    echo $((reset_epoch - now))
}

# Round a float to integer
cu_round() {
    local val="$1"
    printf "%.0f" "$val" 2>/dev/null || echo "${val%.*}"
}
