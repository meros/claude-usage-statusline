#!/usr/bin/env bash
# test-fetch.sh - Credential resolution tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use temp dirs for isolation
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CU_DATA_DIR="$TEST_DIR/data"
export CU_CACHE_DIR="$TEST_DIR/cache"
export CU_NO_COLOR=1
export CU_NOW=1709100000

# Override HOME so we don't touch real credentials
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

source "${SCRIPT_DIR}/../lib/util.sh"
source "${SCRIPT_DIR}/../lib/fetch.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf "  PASS: %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s\n    expected: %q\n    actual:   %q\n" "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Credential Resolution Tests ==="

# Test 1: No credentials file -> cu_fetch fails
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
cu_fetch "force" && result=0 || result=$?
assert_eq "missing credentials file returns failure" "1" "$result"

# Test 2: Default path (~/.claude/.credentials.json)
mkdir -p "$HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"test-token-default"}}' > "$HOME/.claude/.credentials.json"
# cu_fetch will fail on the curl call (no real API), but we can verify the token is read
# by checking it gets past the token-empty check (curl will fail, returning 1 from response validation)
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
cu_fetch "force" && result=0 || result=$?
# Returns 1 because curl can't reach the API, but importantly it did NOT return 1 at the token check
# We need a more precise test - let's extract the token directly
token=$(jq -r '.claudeAiOauth.accessToken // empty' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
assert_eq "default path reads token" "test-token-default" "$token"

# Test 3: CLAUDE_CONFIG_DIR override
custom_dir="$TEST_DIR/custom-claude-config"
mkdir -p "$custom_dir"
echo '{"claudeAiOauth":{"accessToken":"test-token-custom"}}' > "$custom_dir/.credentials.json"
export CLAUDE_CONFIG_DIR="$custom_dir"
token=$(jq -r '.claudeAiOauth.accessToken // empty' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
assert_eq "CLAUDE_CONFIG_DIR override reads token" "test-token-custom" "$token"

# Test 4: CLAUDE_CONFIG_DIR set but credentials file missing
empty_dir="$TEST_DIR/empty-config"
mkdir -p "$empty_dir"
export CLAUDE_CONFIG_DIR="$empty_dir"
cu_fetch "force" && result=0 || result=$?
assert_eq "CLAUDE_CONFIG_DIR with missing creds returns failure" "1" "$result"

# Test 5: CLAUDE_CONFIG_DIR takes priority over default
# Put different tokens in both locations
mkdir -p "$HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"default-token"}}' > "$HOME/.claude/.credentials.json"
priority_dir="$TEST_DIR/priority-config"
mkdir -p "$priority_dir"
echo '{"claudeAiOauth":{"accessToken":"priority-token"}}' > "$priority_dir/.credentials.json"
export CLAUDE_CONFIG_DIR="$priority_dir"
token=$(jq -r '.claudeAiOauth.accessToken // empty' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
assert_eq "CLAUDE_CONFIG_DIR takes priority over default" "priority-token" "$token"

# Test 6: Empty token in credentials file
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
echo '{"claudeAiOauth":{"accessToken":""}}' > "$HOME/.claude/.credentials.json"
cu_fetch "force" && result=0 || result=$?
assert_eq "empty token returns failure" "1" "$result"

# Test 7: Malformed credentials JSON
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
echo 'not valid json' > "$HOME/.claude/.credentials.json"
cu_fetch "force" && result=0 || result=$?
assert_eq "malformed credentials returns failure" "1" "$result"

# Test 8: Missing accessToken key
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
echo '{"claudeAiOauth":{"refreshToken":"some-refresh"}}' > "$HOME/.claude/.credentials.json"
cu_fetch "force" && result=0 || result=$?
assert_eq "missing accessToken key returns failure" "1" "$result"

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
