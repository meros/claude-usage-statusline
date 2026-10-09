#!/usr/bin/env bash
# test-budget.sh - Process budget per statusline render
#
# Claude Code runs the statusline after every message; its cost is mostly
# process starts (jq, awk, date, ...), about 2-3 ms each. This counts them
# with strace for one demo render and fails above the budget, so a change
# that adds a fork per value or per cell shows up here. Process counts are
# stable across machines, wall time is not. Skipped without strace.
#
# Budgets are the measured count (61 multiline, 60 single-line) plus 3 for
# environment differences. Lower them when you remove processes; raise them
# only with a reason.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"
source "${TESTS_DIR}/lib/demo.sh"

BUDGET_MULTILINE=64
BUDGET_SINGLE=63

if ! command -v strace >/dev/null 2>&1 || ! strace -f -z -qq -o /dev/null true 2>/dev/null; then
    echo "  SKIP: strace not available"
    assert_done
    exit
fi

PROJECT="$TEST_DIR/myproject"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main

# Processes one render starts. -z prints only successful execve calls (not
# the PATH lookups that fail), each on one line even when pipelines run in
# parallel, so the count is the same on every run.
count_processes() {
    rm -rf "$TEST_DIR/run"
    demo_build "$TEST_DIR/run/data" "$TEST_DIR/run/cache"
    demo_stdin "$PROJECT" | CU_NOW="$DEMO_NOW" CU_DATA_DIR="$TEST_DIR/run/data" CU_CACHE_DIR="$TEST_DIR/run/cache" \
        strace -f -z -qq -e trace=execve -o "$TEST_DIR/strace.txt" "${REPO_DIR}/bin/claude-usage" statusline "$@" >/dev/null
    grep -c 'execve(' "$TEST_DIR/strace.txt"
}

echo "=== Statusline Process Budget ==="
n=$(count_processes --multiline)
assert_range "multiline render: $n processes, budget $BUDGET_MULTILINE" 1 "$BUDGET_MULTILINE" "$n"
n=$(count_processes)
assert_range "single-line render: $n processes, budget $BUDGET_SINGLE" 1 "$BUDGET_SINGLE" "$n"

assert_done
