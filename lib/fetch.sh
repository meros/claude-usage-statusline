#!/usr/bin/env bash
# fetch.sh - API fetch + caching

CU_CACHE_FILE="${CU_CACHE_DIR}/api-response.json"
CU_CACHE_MAX_AGE="${CU_CACHE_MAX_AGE:-300}"

cu_cache_is_fresh() {
    [ -f "$CU_CACHE_FILE" ] || return 1
    local cache_age now file_mtime
    now=$(cu_now)
    file_mtime=$(stat -c %Y "$CU_CACHE_FILE" 2>/dev/null || stat -f %m "$CU_CACHE_FILE" 2>/dev/null || echo 0)
    cache_age=$((now - file_mtime))
    [ "$cache_age" -lt "$CU_CACHE_MAX_AGE" ]
}

cu_resolve_token() {
    local token=""

    # 1. Try credentials JSON file (Linux default, or macOS manual export)
    local cred_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    cu_log "resolve_token: trying $cred_file"
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)
    if [ -n "$token" ]; then
        cu_log "resolve_token: found token from creds file (${#token} chars)"
        echo "$token"
        return 0
    fi

    # 2. Try macOS Keychain (Claude Code stores creds here on macOS)
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

cu_fetch() {
    local force="${1:-}"
    if [ "$force" != "force" ] && cu_cache_is_fresh; then
        cu_log "fetch: cache is fresh, skipping"
        return 0
    fi

    cu_log "fetch: resolving token"
    local token
    token=$(cu_resolve_token) || return 1

    cu_log "fetch: calling API"
    local resp
    resp=$(curl -s --max-time 5 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

    if [ -z "$resp" ]; then
        cu_log "fetch: empty response (network error or timeout)"
        echo "API request failed (network error or timeout)." >&2
        return 1
    fi

    cu_log "fetch: got response (${#resp} bytes)"

    # Accept response if it has at least one usage window (five_hour or seven_day)
    if echo "$resp" | jq -e '.five_hour // .seven_day' >/dev/null 2>&1; then
        cu_log "fetch: valid usage data, writing cache"
        echo "$resp" > "$CU_CACHE_FILE"
        return 0
    fi

    # Try to extract API error message
    local api_err
    api_err=$(echo "$resp" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$api_err" ]; then
        cu_log "fetch: API error: $api_err"
        echo "API error: $api_err" >&2
    else
        cu_log "fetch: unexpected response: ${resp:0:200}"
        echo "Unexpected API response (no usage data). Token may be expired — try restarting Claude Code." >&2
    fi
    return 1
}

cu_read_cache() {
    [ -f "$CU_CACHE_FILE" ] && cat "$CU_CACHE_FILE" || true
}

cu_get_five_hour_pct() {
    local data="${1:-$(cu_read_cache)}"
    echo "$data" | jq -r '.five_hour.utilization // empty' 2>/dev/null
}

cu_get_five_hour_reset() {
    local data="${1:-$(cu_read_cache)}"
    echo "$data" | jq -r '.five_hour.resets_at // empty' 2>/dev/null
}

cu_get_seven_day_pct() {
    local data="${1:-$(cu_read_cache)}"
    echo "$data" | jq -r '.seven_day.utilization // empty' 2>/dev/null
}

cu_get_seven_day_reset() {
    local data="${1:-$(cu_read_cache)}"
    echo "$data" | jq -r '.seven_day.resets_at // empty' 2>/dev/null
}
