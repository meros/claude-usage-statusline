#!/usr/bin/env bash
# util.sh - Paths, logging, clock, colors and formatting shared by every module

# --- Paths ---------------------------------------------------------------

CU_DATA_DIR="${CU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-usage}"
CU_CACHE_DIR="${CU_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-usage}"

# Derive every file path from CU_DATA_DIR and CU_CACHE_DIR and create the
# directories. Call it again after the directories change (--data-dir,
# --cache-dir), so no path keeps pointing at the old directory.
cu_set_paths() {
    CU_HISTORY_SHORT="${CU_DATA_DIR}/history-short.jsonl"
    CU_HISTORY_LONG="${CU_DATA_DIR}/history-long.jsonl"
    CU_CACHE_FILE="${CU_CACHE_DIR}/api-response.json"
    CU_BACKOFF_FILE="${CU_CACHE_DIR}/rate-limit-backoff"
    CU_FETCH_LOCK="${CU_CACHE_DIR}/fetch.lock"
    CU_UPDATE_CACHE="${CU_CACHE_DIR}/update-check.json"
    CU_SESSION_FILE="${CU_CACHE_DIR}/session-start"
    mkdir -p "$CU_DATA_DIR" "$CU_CACHE_DIR"
}
cu_set_paths

# --- Logging -------------------------------------------------------------

# CU_DEBUG=1 enables logging to stderr; CU_LOG_FILE=path sends it to a file.
cu_log() {
    [ "${CU_DEBUG:-}" = "1" ] || return 0
    local msg="[claude-usage] $*"
    if [ -n "${CU_LOG_FILE:-}" ]; then
        echo "$msg" >> "$CU_LOG_FILE"
    else
        echo "$msg" >&2
    fi
}

# --- Clock ---------------------------------------------------------------

# Current epoch. CU_NOW overrides it for deterministic tests.
cu_now() {
    if [ -n "${CU_NOW:-}" ]; then
        echo "$CU_NOW"
    else
        date +%s
    fi
}

# File modification time as epoch (GNU stat, then BSD stat), 0 if missing.
cu_file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Seconds since the file was last modified, relative to cu_now.
cu_file_age() {
    echo $(( $(cu_now) - $(cu_file_mtime "$1") ))
}

# ISO 8601 timestamp to epoch (GNU date, then BSD date). Empty on failure.
cu_iso_to_epoch() {
    local iso="$1"
    [ -z "$iso" ] && return 1
    date -d "$iso" +%s 2>/dev/null ||
        date -j -u -f "%Y-%m-%dT%H:%M:%S" "${iso%%[.Z+]*}" +%s 2>/dev/null
}

# Seconds from now until an ISO 8601 timestamp (negative when it is past).
cu_secs_until_reset() {
    local iso="$1" reset_epoch
    [ -z "$iso" ] && { echo 0; return; }
    reset_epoch=$(cu_iso_to_epoch "$iso") || { echo 0; return; }
    echo $(( reset_epoch - $(cu_now) ))
}

# --- Colors --------------------------------------------------------------

# NO_COLOR (https://no-color.org) or --no-color disable all ANSI output.
CU_NO_COLOR="${CU_NO_COLOR:-${NO_COLOR:-}}"

cu_color() {
    [ -n "$CU_NO_COLOR" ] && return
    printf '\033[%sm' "$1"
}

cu_reset() {
    [ -n "$CU_NO_COLOR" ] && return
    printf '\033[0m'
}

# Gruvbox-inspired palette (24-bit foreground SGR codes)
CU_GREEN="38;2;142;192;124"
CU_YELLOW="38;2;250;189;47"
CU_RED="38;2;251;73;52"
CU_AQUA="38;2;131;165;152"
CU_PURPLE="38;2;211;134;155"
CU_ORANGE="38;2;254;128;25"
CU_FG="38;2;235;219;178"
CU_DIM="38;2;146;131;116"

# Color for a usage percentage: green below CU_PCT_WARN, yellow below
# CU_PCT_CRIT, red from there.
cu_pct_color() {
    local pct="${1%.*}"
    pct="${pct:-0}"
    if [ "$pct" -ge "${CU_PCT_CRIT:-80}" ]; then
        echo "$CU_RED"
    elif [ "$pct" -ge "${CU_PCT_WARN:-50}" ]; then
        echo "$CU_YELLOW"
    else
        echo "$CU_GREEN"
    fi
}

# --- Formatting ----------------------------------------------------------

# Seconds as "2d 3h", "4h 12m" or "7m"; negative is "now".
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

# Epoch as a short local day and hour: "Fri 9am".
cu_fmt_day_hour() {
    # GNU date has %P (lowercase am/pm); BSD date only %p, so lowercase it.
    LC_TIME=C date -d "@$1" "+%a %-l%P" 2>/dev/null ||
        LC_TIME=C date -r "$1" "+%a %-l%p" 2>/dev/null | tr 'AP' 'ap'
}

# ISO 8601 reset time as "Fri 9am".
cu_fmt_reset_date() {
    local epoch
    epoch=$(cu_iso_to_epoch "$1") || return 0
    cu_fmt_day_hour "$epoch"
}

# A point SECS from now as "Fri 9am" (for ETAs).
cu_fmt_eta_date() {
    cu_fmt_day_hour $(( $(cu_now) + $1 ))
}

# Visible length of a string: characters after stripping ANSI color codes.
# Pure bash (no fork; the statusline measures every cell). Counts UTF-8 lead
# bytes in the C locale, so the result does not depend on the user's locale.
cu_visible_len() {
    local s="$1" re=$'\e\\[[0-9;]*m'
    while [[ "$s" =~ $re ]]; do
        s="${s/"${BASH_REMATCH[0]}"/}"
    done
    local LC_ALL=C
    s="${s//[$'\x80'-$'\xbf']/}"
    echo "${#s}"
}

# Split a comma-separated list into words: "a,b" -> "a b"
cu_words() {
    printf '%s' "${1//,/ }"
}
