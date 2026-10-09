#!/usr/bin/env bash
# fetch.sh - Usage data: OAuth API fetch, rate-limit backoff, cache, stdin input
#
# The cache file holds the last good API response:
#   {"five_hour": {"utilization": 30, "resets_at": "<iso>"}, "seven_day": {...}}
# Its mtime is the time of the last successful refresh. When the API rate-limits
# us before any data exists, the cache holds a sentinel instead:
#   {"_error": "rate_limited", "_retry_at": <epoch>}

CU_USAGE_URL="${CU_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
CU_BACKOFF_MAX=1800  # cap for the exponential backoff, seconds

cu_cache_is_fresh() {
    [ -f "$CU_CACHE_FILE" ] || return 1
    [ "$(cu_file_age "$CU_CACHE_FILE")" -lt "$CU_CACHE_MAX_AGE" ]
}

# Seconds since the last successful refresh (0 when there is no cache).
cu_cache_age() {
    [ -f "$CU_CACHE_FILE" ] || { echo 0; return; }
    cu_file_age "$CU_CACHE_FILE"
}

# Current backoff duration in seconds (the backoff file holds it).
cu_backoff_duration() {
    local dur
    dur=$(cat "$CU_BACKOFF_FILE" 2>/dev/null)
    echo "${dur:-$CU_CACHE_MAX_AGE}"
}

# Seconds left in the rate-limit backoff; 0 or less when it is over.
cu_backoff_remaining() {
    [ -f "$CU_BACKOFF_FILE" ] || { echo 0; return; }
    echo $(( $(cu_backoff_duration) - $(cu_file_age "$CU_BACKOFF_FILE") ))
}

cu_is_backing_off() {
    [ "$(cu_backoff_remaining)" -gt 0 ]
}

# Print the Claude Code OAuth access token. Looks in
# $CLAUDE_CONFIG_DIR/.credentials.json (default ~/.claude), then in the macOS
# Keychain item "Claude Code-credentials".
cu_resolve_token() {
    local token=""
    local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    cu_log "resolve_token: trying $cred_file"
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)
    if [ -n "$token" ]; then
        cu_log "resolve_token: found token from creds file (${#token} chars)"
        echo "$token"
        return 0
    fi

    if command -v security >/dev/null 2>&1; then
        local keychain_data
        keychain_data=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || true
        if [ -n "$keychain_data" ]; then
            token=$(echo "$keychain_data" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ]; then
                cu_log "resolve_token: found token from keychain (${#token} chars)"
                echo "$token"
                return 0
            fi
        fi
    fi

    cu_log "resolve_token: no credentials found"
    echo "No Claude credentials found. Expected ${cred_file} or macOS Keychain entry." >&2
    return 1
}

# Take the fetch lock on fd 9 so parallel statuslines do not all call the API.
# Returns 0 when this process should fetch, 1 when another process refreshed
# the cache meanwhile (or still holds the lock). Without flock (macOS has none
# by default) it fetches unlocked.
_cu_fetch_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$CU_FETCH_LOCK"
    flock -n 9 && return 0

    cu_log "fetch: waiting for another process to finish fetching"
    flock -w 10 9 2>/dev/null || true
    exec 9>&-
    cu_cache_is_fresh && return 1
    # The other process failed; try once more ourselves.
    exec 9>"$CU_FETCH_LOCK"
    flock -n 9 && return 0
    exec 9>&-
    return 1
}

_cu_fetch_unlock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>&-
}

# Double the backoff on each consecutive rate-limit error, up to CU_BACKOFF_MAX.
_cu_start_backoff() {
    local retry_secs="$CU_CACHE_MAX_AGE"
    if [ -f "$CU_BACKOFF_FILE" ]; then
        retry_secs=$(( $(cu_backoff_duration) * 2 ))
        [ "$retry_secs" -gt "$CU_BACKOFF_MAX" ] && retry_secs="$CU_BACKOFF_MAX"
    fi
    cu_log "fetch: rate limited, backing off ${retry_secs}s"
    echo "$retry_secs" > "$CU_BACKOFF_FILE"
    # The cache mtime is not touched: it shows when data was last updated.
    if [ ! -f "$CU_CACHE_FILE" ]; then
        cu_log "fetch: no cache exists, writing sentinel"
        local tmp="${CU_CACHE_FILE}.tmp.$$"
        printf '{"_error":"rate_limited","_retry_at":%d}\n' "$(( $(cu_now) + CU_CACHE_MAX_AGE ))" > "$tmp"
        mv "$tmp" "$CU_CACHE_FILE"
    fi
}

# Refresh the cache from the API. Skips the call while the cache is fresh or
# during a rate-limit backoff, unless the first argument is "force".
# Returns 0 when the cache holds fresh data afterwards.
cu_fetch() {
    local force="${1:-}"
    if [ "$force" != "force" ]; then
        if cu_cache_is_fresh; then
            cu_log "fetch: cache is fresh, skipping"
            return 0
        fi
        if cu_is_backing_off; then
            cu_log "fetch: in rate-limit backoff, skipping"
            return 1
        fi
    fi

    if ! _cu_fetch_lock; then
        cu_cache_is_fresh
        return
    fi
    # Another process may have refreshed the cache while we waited.
    if [ "$force" != "force" ] && cu_cache_is_fresh; then
        cu_log "fetch: cache refreshed while waiting for lock"
        _cu_fetch_unlock
        return 0
    fi

    local token resp
    token=$(cu_resolve_token) || { _cu_fetch_unlock; return 1; }
    cu_log "fetch: calling API"
    resp=$(curl -s --max-time 5 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "$CU_USAGE_URL" 2>/dev/null)
    _cu_fetch_unlock

    if [ -z "$resp" ]; then
        cu_log "fetch: empty response (network error or timeout)"
        echo "API request failed (network error or timeout)." >&2
        return 1
    fi
    cu_log "fetch: got response (${#resp} bytes)"

    if echo "$resp" | jq -e '.five_hour // .seven_day' >/dev/null 2>&1; then
        cu_log "fetch: valid usage data, writing cache"
        cu_write_cache "$resp"
        return 0
    fi

    local api_err err_type
    api_err=$(echo "$resp" | jq -r '.error.message // empty' 2>/dev/null)
    err_type=$(echo "$resp" | jq -r '.error.type // empty' 2>/dev/null)
    if [ -n "$api_err" ]; then
        cu_log "fetch: API error: $api_err"
        echo "API error: $api_err" >&2
        [ "$err_type" = "rate_limit_error" ] && _cu_start_backoff
    else
        cu_log "fetch: unexpected response: ${resp:0:200}"
        echo "Unexpected API response (no usage data). Token may be expired — try restarting Claude Code." >&2
    fi
    return 1
}

cu_read_cache() {
    if [ -f "$CU_CACHE_FILE" ]; then cat "$CU_CACHE_FILE"; fi
}

# Atomic cache write. Clears any rate-limit backoff since we now have fresh data.
cu_write_cache() {
    local payload="${1:-}"
    [ -z "$payload" ] && return 1
    mkdir -p "$CU_CACHE_DIR"
    local tmp="${CU_CACHE_FILE}.tmp.$$"
    printf '%s\n' "$payload" > "$tmp" && mv "$tmp" "$CU_CACHE_FILE"
    rm -f "$CU_BACKOFF_FILE"
    # A process killed between write and rename leaves its temp file behind.
    find "$CU_CACHE_DIR" -maxdepth 1 -name 'api-response.json.tmp.*' -mmin +5 -delete 2>/dev/null || true
}

# Translate Claude Code v2.1.80+ stdin rate_limits into our cache schema.
# Avoids /api/oauth/usage which is aggressively rate-limited (anthropics/claude-code#31637).
# Input  (CC stdin):   {"rate_limits": {"five_hour": {"used_percentage": N, "resets_at": <unix>}, "seven_day": {...}}}
# Output (cache):      {"five_hour": {"utilization": N, "resets_at": "<iso>"}, "seven_day": {...}}
# Returns 1 with no output when rate_limits is absent or empty.
cu_extract_piped_usage() {
    local input="${1:-}"
    [ -z "$input" ] && return 1
    echo "$input" | jq -e '.rate_limits | (.five_hour // .seven_day)' >/dev/null 2>&1 || return 1
    echo "$input" | jq -c '
        def to_iso:
            if . == null then null
            elif type == "number" then (if . == 0 then null else todate end)
            elif type == "string" then .
            else null end;
        def window:
            if . == null then null
            else {utilization: .used_percentage, resets_at: (.resets_at | to_iso)} end;
        {
            five_hour: (.rate_limits.five_hour | window),
            seven_day: (.rate_limits.seven_day | window)
        }
    '
}

# Fields of a cache payload (default: the cache file).
# Usage: cu_usage_field WINDOW utilization|resets_at [DATA]
cu_usage_field() {
    local window="$1" key="$2" data="${3:-$(cu_read_cache)}"
    echo "$data" | jq -r --arg w "$window" --arg k "$key" '.[$w][$k] // empty' 2>/dev/null
}

cu_get_five_hour_pct()   { cu_usage_field five_hour utilization "${1:-}"; }
cu_get_five_hour_reset() { cu_usage_field five_hour resets_at "${1:-}"; }
cu_get_seven_day_pct()   { cu_usage_field seven_day utilization "${1:-}"; }
cu_get_seven_day_reset() { cu_usage_field seven_day resets_at "${1:-}"; }
