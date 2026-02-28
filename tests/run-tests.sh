#!/usr/bin/env bash
# run-tests.sh - Test runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
SUITES=0
FAILED_SUITES=()

run_suite() {
    local name="$1" script="$2"
    echo ""
    echo "━━━ $name ━━━"
    SUITES=$((SUITES + 1))
    if bash "$script"; then
        echo "  ✓ Suite passed"
    else
        echo "  ✗ Suite FAILED"
        FAILED_SUITES+=("$name")
    fi
}

run_suite "Render Tests" "${SCRIPT_DIR}/test-render.sh"
run_suite "History Tests" "${SCRIPT_DIR}/test-history.sh"
run_suite "ETA Tests" "${SCRIPT_DIR}/test-eta.sh"
run_suite "Fetch Tests" "${SCRIPT_DIR}/test-fetch.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Suites: $SUITES total, ${#FAILED_SUITES[@]} failed"

if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo "Failed: ${FAILED_SUITES[*]}"
    exit 1
else
    echo "All suites passed!"
fi
