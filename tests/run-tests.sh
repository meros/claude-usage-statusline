#!/usr/bin/env bash
# run-tests.sh - Run every tests/test-*.sh suite
#
# Usage: bash tests/run-tests.sh [suite-name ...]   e.g. run-tests.sh fetch cli
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TZ=Europe/Stockholm  # snapshots and pace tests use local time

suites=()
if [ $# -gt 0 ]; then
    for name in "$@"; do suites+=("${SCRIPT_DIR}/test-${name}.sh"); done
else
    suites=("${SCRIPT_DIR}"/test-*.sh)
fi

failed=()
for suite in "${suites[@]}"; do
    name=$(basename "$suite" .sh)
    echo ""
    echo "━━━ ${name#test-} ━━━"
    if bash "$suite"; then
        echo "  ✓ Suite passed"
    else
        echo "  ✗ Suite FAILED"
        failed+=("${name#test-}")
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Suites: ${#suites[@]} total, ${#failed[@]} failed"
if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}"
    exit 1
fi
echo "All suites passed!"
