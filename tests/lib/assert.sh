#!/usr/bin/env bash
# assert.sh - Shared assertions for the test suites
#
# Every assertion prints PASS/FAIL and counts the result. End each suite with
# assert_done, which prints the totals and returns non-zero on any failure.

PASS=0
FAIL=0

_assert_pass() {
    printf "  PASS: %s\n" "$1"
    PASS=$((PASS + 1))
}

_assert_fail() {
    printf "  FAIL: %s\n" "$1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
}

# assert_eq DESC EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then
        _assert_pass "$1"
    else
        _assert_fail "$1" "$(printf 'expected: %q\nactual:   %q' "$2" "$3")"
    fi
}

# assert_contains DESC NEEDLE HAYSTACK
assert_contains() {
    if [[ "$3" == *"$2"* ]]; then
        _assert_pass "$1"
    else
        _assert_fail "$1" "$(printf 'expected to contain: %q\nactual: %q' "$2" "$3")"
    fi
}

# assert_not_contains DESC NEEDLE HAYSTACK
assert_not_contains() {
    if [[ "$3" != *"$2"* ]]; then
        _assert_pass "$1"
    else
        _assert_fail "$1" "$(printf 'expected not to contain: %q\nactual: %q' "$2" "$3")"
    fi
}

# assert_nonzero DESC ACTUAL - ACTUAL is non-empty and not "0"
assert_nonzero() {
    if [ -n "$2" ] && [ "$2" != "0" ]; then
        _assert_pass "$1"
    else
        _assert_fail "$1" "expected non-zero, got '$2'"
    fi
}

# assert_range DESC MIN MAX ACTUAL - inclusive, numeric (floats allowed)
assert_range() {
    if awk -v a="$4" -v lo="$2" -v hi="$3" 'BEGIN { exit !(a >= lo && a <= hi) }'; then
        _assert_pass "$1 (got $4)"
    else
        _assert_fail "$1" "got $4, expected range [$2, $3]"
    fi
}

# assert_status DESC EXPECTED_STATUS COMMAND... - runs COMMAND, checks its exit status
assert_status() {
    local desc="$1" expected="$2"; shift 2
    local status=0
    "$@" >/dev/null 2>&1 || status=$?
    assert_eq "$desc" "$expected" "$status"
}

# Write an executable mock script from stdin, with this bash as interpreter
# (a #! line in the input is dropped; /usr/bin/env may not exist).
make_mock() {
    { echo "#!$BASH"; grep -v '^#!'; } > "$1"
    chmod +x "$1"
}

# Strip ANSI color sequences
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

assert_done() {
    echo ""
    printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}
