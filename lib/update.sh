#!/usr/bin/env bash
# update.sh - "Update available" notice for git-clone installs
#
# A background `git ls-remote` compares origin/main with the local HEAD, at
# most once per CU_UPDATE_TTL seconds. The statusline shows the notice for the
# first 15 seconds of a session. Nix installs have no .git and skip the check.

# Start the check in the background; never blocks.
# Args: repository root (default: CU_ROOT_DIR, set by bin/claude-usage)
cu_update_check_bg() {
    [ "${CU_UPDATE_CHECK:-1}" = "0" ] && return 0
    local repo_dir="${1:-${CU_ROOT_DIR:-}}"
    [ -n "$repo_dir" ] && [ -d "$repo_dir/.git" ] || return 0
    if [ -f "$CU_UPDATE_CACHE" ] && [ "$(cu_file_age "$CU_UPDATE_CACHE")" -lt "${CU_UPDATE_TTL:-3600}" ]; then
        return 0
    fi

    (
        remote_head=$(git -C "$repo_dir" ls-remote --heads origin main 2>/dev/null | awk '{print $1}') || true
        [ -z "$remote_head" ] && exit 0
        local_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || true
        [ -z "$local_head" ] && exit 0
        available=0
        [ "$remote_head" != "$local_head" ] && available=1
        printf '{"available":%d,"remote":"%s","local":"%s","checked":%d}\n' \
            "$available" "$remote_head" "$local_head" "$(date +%s)" > "$CU_UPDATE_CACHE"
    ) &>/dev/null &
    disown 2>/dev/null || true
}

# Print the notice when an update is available and the session is younger
# than 15 seconds. A session starts at the first render after 5 minutes
# without one. The session file holds an epoch (not its mtime), so CU_NOW
# works in tests.
cu_update_message() {
    [ "${CU_UPDATE_CHECK:-1}" = "0" ] && return 0
    [ -f "$CU_UPDATE_CACHE" ] || return 0
    [ "$(jq -r '.available // 0' "$CU_UPDATE_CACHE" 2>/dev/null)" = "1" ] || return 0

    local now session_start age
    now=$(cu_now)
    session_start=$(cat "$CU_SESSION_FILE" 2>/dev/null)
    age=$(( now - ${session_start:-0} ))
    if [ ! -f "$CU_SESSION_FILE" ] || [ "$age" -gt 300 ]; then
        printf '%s' "$now" > "$CU_SESSION_FILE"
    elif [ "$age" -gt 15 ]; then
        return 0
    fi

    printf '%s↑ Update available%s' "$(cu_color "$CU_DIM")" "$(cu_reset)"
}
