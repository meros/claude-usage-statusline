#!/usr/bin/env bash
# update.sh - Background version update checking

CU_UPDATE_CACHE="${CU_CACHE_DIR}/update-check.json"
CU_SESSION_FILE="${CU_CACHE_DIR}/session-start"

cu_update_check_bg() {
    # Spawn background check for newer version via git ls-remote
    # Caches result with configurable TTL; never blocks the statusline
    [ "${CU_UPDATE_CHECK:-1}" = "0" ] && return 0

    # Check cache freshness
    if [ -f "$CU_UPDATE_CACHE" ]; then
        local cache_age now file_mtime
        now=$(cu_now)
        file_mtime=$(stat -c %Y "$CU_UPDATE_CACHE" 2>/dev/null || stat -f %m "$CU_UPDATE_CACHE" 2>/dev/null || echo 0)
        cache_age=$((now - file_mtime))
        [ "$cache_age" -lt "${CU_UPDATE_TTL:-3600}" ] && return 0
    fi

    # Find repo root (works for both git clone and nix installs)
    local repo_dir=""
    if [ -d "${SCRIPT_DIR}/../.git" ]; then
        repo_dir="${SCRIPT_DIR}/.."
    elif [ -d "${LIB_DIR}/../.git" ]; then
        repo_dir="${LIB_DIR}/.."
    fi
    [ -z "$repo_dir" ] && return 0

    # Run in background subshell — never blocks
    (
        local remote_head local_head
        remote_head=$(git -C "$repo_dir" ls-remote --heads origin main 2>/dev/null | awk '{print $1}') || true
        [ -z "$remote_head" ] && exit 0

        local_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || true
        [ -z "$local_head" ] && exit 0

        local update_available=0
        [ "$remote_head" != "$local_head" ] && update_available=1

        printf '{"available":%d,"remote":"%s","local":"%s","checked":%d}\n' \
            "$update_available" "$remote_head" "$local_head" "$(date +%s)" \
            > "$CU_UPDATE_CACHE"
    ) &>/dev/null &
    disown 2>/dev/null || true
}

cu_update_message() {
    # Returns update notification string if:
    # 1. Update check is enabled
    # 2. Cache says update is available
    # 3. Session is <15s old (show briefly at start)
    [ "${CU_UPDATE_CHECK:-1}" = "0" ] && return 0
    [ -f "$CU_UPDATE_CACHE" ] || return 0

    local available
    available=$(jq -r '.available // 0' "$CU_UPDATE_CACHE" 2>/dev/null)
    [ "$available" = "1" ] || return 0

    # Session tracking: show notification only in first 15s of a session
    # Uses file content (epoch) instead of mtime so CU_NOW works in tests
    local now
    now=$(cu_now)

    if [ -f "$CU_SESSION_FILE" ]; then
        local session_start
        session_start=$(cat "$CU_SESSION_FILE" 2>/dev/null)
        session_start="${session_start:-0}"
        local session_age=$((now - session_start))

        if [ "$session_age" -gt 300 ]; then
            # Session file is >5 min old — treat as new session
            printf '%s' "$now" > "$CU_SESSION_FILE"
        elif [ "$session_age" -gt 15 ]; then
            # Past the 15s notification window
            return 0
        fi
    else
        # First render of a new session
        printf '%s' "$now" > "$CU_SESSION_FILE"
    fi

    printf '%s↑ Update available%s' "$(cu_color "$CU_DIM")" "$(cu_reset)"
}
