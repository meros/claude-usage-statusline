#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154  # mock scripts in single quotes; task_* come from task.sh
# test-task.sh - Per-session task label lookup
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"

export CU_TASK_ENABLED=1
CU_TASK_ENABLED=1
CU_TASK_STATE_DIR="$TEST_DIR/state"
CU_TASK_HELPER="$TEST_DIR/no-helper"
mkdir -p "$CU_TASK_STATE_DIR"
echo "[api] fix login" > "$CU_TASK_STATE_DIR/pid-4242"
printf '2/5 tests ~15m\nsecond line\n' > "$CU_TASK_STATE_DIR/progress-4242"

echo "=== Task Label ==="
CU_TASK_PID=4242 cu_task_info
assert_eq "label from pid file" "[api] fix login" "$task_desc"
assert_eq "progress from first line" "2/5 tests ~15m" "$task_progress"

CU_TASK_PID=1111 cu_task_info
assert_eq "no file for this session -> no label" "" "$task_desc"
assert_eq "no file for this session -> no progress" "" "$task_progress"

CU_TASK_ENABLED=0 CU_TASK_PID=4242 cu_task_info
assert_eq "CU_TASK_ENABLED=0 hides the label" "" "$task_desc"

echo ""
echo "=== Progress Helper ==="
echo '[ "$1" = summary ] && echo "2/5 tests · 12m left"' | make_mock "$TEST_DIR/helper"
chmod +x "$TEST_DIR/helper"
CU_TASK_HELPER="$TEST_DIR/helper" CU_TASK_PID=4242 cu_task_info
assert_eq "helper output wins" "2/5 tests · 12m left" "$task_progress"

echo 'exit 1' | make_mock "$TEST_DIR/failing"
chmod +x "$TEST_DIR/failing"
CU_TASK_HELPER="$TEST_DIR/failing" CU_TASK_PID=4242 cu_task_info
assert_eq "failing helper falls back to the file" "2/5 tests ~15m" "$task_progress"

echo ""
echo "=== Process Walk ==="
# Run a copy of bash named "claude"; the walk from its child finds it.
mkdir -p "$TEST_DIR/fake"
ln -s "$(command -v bash)" "$TEST_DIR/fake/claude"
if [ -d /proc/self ]; then
    "$TEST_DIR/fake/claude" -c 'bash -c "source \"$1/task.sh\"; unset CU_TASK_PID; cu_task_claude_pid" > "$2/found"; echo $$ > "$2/expected"' \
        _ "$CU_LIB_DIR" "$TEST_DIR"
    assert_eq "finds the nearest claude ancestor" "$(cat "$TEST_DIR/expected")" "$(cat "$TEST_DIR/found")"
else
    echo "  SKIP: no /proc"
fi

assert_done
