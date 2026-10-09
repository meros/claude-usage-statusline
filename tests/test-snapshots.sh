#!/usr/bin/env bash
# shellcheck disable=SC2016  # $HOME in scenario env is expanded per scenario
# test-snapshots.sh - End-to-end output of every view against the demo dataset
#
# Each scenario runs bin/claude-usage as a process with a fresh copy of the
# demo data and compares its output (ANSI colors included) with
# tests/snapshots/<name>.txt. To accept a deliberate output change:
#   UPDATE_SNAPSHOTS=1 bash tests/test-snapshots.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/assert.sh"
source "${SCRIPT_DIR}/lib/demo.sh"

BIN="${BIN:-${SCRIPT_DIR}/../bin/claude-usage}"
SNAP_DIR="${SCRIPT_DIR}/snapshots"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# A git repo named like a real project, so the header shows dir + branch.
PROJECT="$TEST_DIR/myproject"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main

# Run one scenario: snap NAME [ENV=VAL ...] -- ARGS...
# stdin of the scenario comes from $SNAP_STDIN when set.
snap() {
    local name="$1"; shift
    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift

    local home="$TEST_DIR/$name"
    rm -rf "$home"
    mkdir -p "$home"
    demo_build "$home/data" "$home/cache"
    [ -n "${SNAP_SETUP:-}" ] && "$SNAP_SETUP" "$home"

    local out
    out=$(env -i PATH="$PATH" HOME="$home" TZ=Europe/Stockholm ${TZDIR:+TZDIR="$TZDIR"} LC_ALL=C.UTF-8 \
        CU_NOW="$DEMO_NOW" CU_UPDATE_CHECK=0 \
        CU_DATA_DIR="$home/data" CU_CACHE_DIR="$home/cache" \
        CLAUDE_CONFIG_DIR="$home/claude" \
        ${envs[@]+"${envs[@]//\$HOME/$home}"} \
        "$BIN" "$@" <<< "${SNAP_STDIN:-}" 2>&1) || true

    local file="$SNAP_DIR/$name.txt"
    if [ "${UPDATE_SNAPSHOTS:-}" = "1" ]; then
        mkdir -p "$SNAP_DIR"
        printf '%s\n' "$out" > "$file"
        printf "  UPDATED: %s\n" "$name"
        return
    fi
    if [ ! -f "$file" ]; then
        _assert_fail "$name" "snapshot file missing: $file"
        return
    fi
    local expected
    expected=$(cat "$file")
    if [ "$expected" = "$out" ]; then
        _assert_pass "$name"
    else
        _assert_fail "$name" "output differs from $file:
$(diff <(printf '%s\n' "$expected" | cat -v) <(printf '%s\n' "$out" | cat -v) | head -20)"
    fi
}

stale_cache() {
    # Cache last refreshed 2 hours before "now", API in a 10-minute backoff.
    touch -d "@$((DEMO_NOW - 7200))" "$1/cache/api-response.json"
    echo 600 > "$1/cache/rate-limit-backoff"
    touch -d "@$((DEMO_NOW - 60))" "$1/cache/rate-limit-backoff"
}

task_state() {
    mkdir -p "$1/state"
    echo "[api] fix login redirect" > "$1/state/pid-4242"
    echo "2/5 tests ~15m" > "$1/state/progress-4242"
}

rate_limited_cache() {
    printf '{"_error":"rate_limited","_retry_at":%d}\n' "$((DEMO_NOW + 300))" > "$1/cache/api-response.json"
}

echo "=== Statusline ==="
SNAP_STDIN=$(demo_stdin "$PROJECT")
snap statusline-single -- statusline
snap statusline-multiline -- statusline --multiline
snap statusline-multiline-block CU_SPARKLINE_TYPE=block -- statusline --multiline
snap statusline-modules CU_MODULES=pct,eta,reset -- statusline --multiline
snap statusline-five-hour-only -- statusline --windows five_hour
snap statusline-no-color -- statusline --multiline --no-color
snap statusline-custom-endpoint ANTHROPIC_BASE_URL=http://127.0.0.1:4000 -- statusline --multiline
snap statusline-no-header CU_HEADER_MODULES= -- statusline --multiline
snap statusline-no-header-single CU_HEADER_MODULES= -- statusline
snap statusline-pace-off CU_PACE_ENABLED=0 -- statusline --multiline
snap statusline-pace-weekdays CU_PACE_WORK_DAYS=mon-thu CU_PACE_WORK_HOURS=09-17 -- statusline --multiline
snap statusline-flat-eta CU_ETA_TEMPLATE=0 -- statusline --multiline
snap statusline-thresholds CU_PCT_WARN=20 CU_PCT_CRIT=60 -- statusline --multiline
SNAP_SETUP=task_state snap statusline-task CU_TASK_PID=4242 'CU_TASK_STATE_DIR=$HOME/state' -- statusline --multiline

SNAP_STDIN=$(demo_stdin "$PROJECT" 0)
snap statusline-from-cache -- statusline --no-fetch
SNAP_SETUP=stale_cache snap statusline-stale -- statusline --no-fetch
SNAP_SETUP=rate_limited_cache snap statusline-rate-limited -- statusline --multiline --no-fetch
SNAP_SETUP=rate_limited_cache snap statusline-rate-limited-single -- statusline --no-fetch
unset SNAP_STDIN

echo ""
echo "=== Other commands ==="
snap dashboard -- show --no-fetch
snap dashboard-block CU_SPARKLINE_TYPE=block -- show --no-fetch
snap dashboard-flat-eta CU_ETA_TEMPLATE=0 -- show --no-fetch
snap eta -- eta --no-fetch
snap sparkline-long -- sparkline --no-fetch
snap sparkline-short-braille -- sparkline --no-fetch --tier short --hours 5 --braille --width 16
snap history-view -- history-view --no-color --hours 3
snap debug-template -- debug-template --no-fetch

assert_done
