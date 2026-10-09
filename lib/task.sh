#!/usr/bin/env bash
# task.sh - Per-session task label and progress for the statusline header
#
# Optional integration. A hook in your Claude Code setup writes a short label
# for each Claude session to a state directory, keyed by the PID of the
# claude process:
#   $CU_TASK_STATE_DIR/pid-<PID>       first line = task label ("[api] fix login")
#   $CU_TASK_STATE_DIR/progress-<PID>  first line = progress ("2/5 review ~15m")
# The statusline runs as a child of that claude process, so it finds the PID
# by walking up its parent processes (Linux /proc only).
#
# When CU_TASK_HELPER is executable, "$CU_TASK_HELPER summary" gives the
# progress text instead of the raw file (for example with the ETA counted down).
#
# Settings:
#   CU_TASK_ENABLED     1 (default) or 0
#   CU_TASK_STATE_DIR   default ~/.local/state/claude-tasks
#   CU_TASK_HELPER      default ~/.claude/hooks/claude-task.sh
#   CU_TASK_PID         use this PID instead of walking the process tree

CU_TASK_ENABLED="${CU_TASK_ENABLED:-1}"
CU_TASK_STATE_DIR="${CU_TASK_STATE_DIR:-$HOME/.local/state/claude-tasks}"
CU_TASK_HELPER="${CU_TASK_HELPER:-$HOME/.claude/hooks/claude-task.sh}"

# PID of the nearest ancestor process named claude (the nix wrapper renames
# the binary to .claude-unwrapped). Prints nothing when there is none.
cu_task_claude_pid() {
    if [ -n "${CU_TASK_PID:-}" ]; then
        echo "$CU_TASK_PID"
        return
    fi
    local pid=$$ comm
    while [ "$pid" -gt 1 ] 2>/dev/null; do
        comm=$(cat /proc/"$pid"/comm 2>/dev/null) || return 0
        case "$comm" in
            .claude-unwrapp*|claude) echo "$pid"; return ;;
        esac
        pid=$(awk '{print $4}' /proc/"$pid"/stat 2>/dev/null) || return 0
    done
}

# Load the label and progress of this Claude session into task_desc and
# task_progress (both empty when not available).
cu_task_info() {
    task_desc=""
    task_progress=""
    [ "$CU_TASK_ENABLED" = "1" ] || return 0

    local pid
    pid=$(cu_task_claude_pid)
    [ -n "$pid" ] || return 0

    [ -f "$CU_TASK_STATE_DIR/pid-$pid" ] &&
        task_desc=$(head -1 "$CU_TASK_STATE_DIR/pid-$pid" 2>/dev/null)
    # The helper's answer wins when it succeeds, even when empty.
    if [ -x "$CU_TASK_HELPER" ] && task_progress=$("$CU_TASK_HELPER" summary 2>/dev/null); then
        return 0
    fi
    task_progress=""
    [ -f "$CU_TASK_STATE_DIR/progress-$pid" ] &&
        task_progress=$(head -1 "$CU_TASK_STATE_DIR/progress-$pid" 2>/dev/null)
    return 0
}
