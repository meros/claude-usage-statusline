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

# Remove any real `security` command from PATH so it doesn't interfere
# We'll add a mock when testing the Keychain fallback
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "^$" | while read -r p; do
    [ -x "$p/security" ] || printf '%s:' "$p"
done)
CLEAN_PATH="${CLEAN_PATH%:}"

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

# Test 1: No credentials file -> cu_resolve_token fails
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
PATH="$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "missing credentials file returns failure" "1" "$result"

# Test 2: Default path (~/.claude/.credentials.json)
mkdir -p "$HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"test-token-default"}}' > "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
token=$(cu_resolve_token)
assert_eq "default path reads token" "test-token-default" "$token"

# Test 3: CLAUDE_CONFIG_DIR override
custom_dir="$TEST_DIR/custom-claude-config"
mkdir -p "$custom_dir"
echo '{"claudeAiOauth":{"accessToken":"test-token-custom"}}' > "$custom_dir/.credentials.json"
export CLAUDE_CONFIG_DIR="$custom_dir"
token=$(cu_resolve_token)
assert_eq "CLAUDE_CONFIG_DIR override reads token" "test-token-custom" "$token"

# Test 4: CLAUDE_CONFIG_DIR set but credentials file missing (no keychain either)
empty_dir="$TEST_DIR/empty-config"
mkdir -p "$empty_dir"
export CLAUDE_CONFIG_DIR="$empty_dir"
PATH="$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "CLAUDE_CONFIG_DIR with missing creds returns failure" "1" "$result"

# Test 5: CLAUDE_CONFIG_DIR takes priority over default
mkdir -p "$HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"default-token"}}' > "$HOME/.claude/.credentials.json"
priority_dir="$TEST_DIR/priority-config"
mkdir -p "$priority_dir"
echo '{"claudeAiOauth":{"accessToken":"priority-token"}}' > "$priority_dir/.credentials.json"
export CLAUDE_CONFIG_DIR="$priority_dir"
token=$(cu_resolve_token)
assert_eq "CLAUDE_CONFIG_DIR takes priority over default" "priority-token" "$token"

# Test 6: Empty token in credentials file
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
echo '{"claudeAiOauth":{"accessToken":""}}' > "$HOME/.claude/.credentials.json"
PATH="$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "empty token returns failure" "1" "$result"

# Test 7: Malformed credentials JSON
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
echo 'not valid json' > "$HOME/.claude/.credentials.json"
PATH="$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "malformed credentials returns failure" "1" "$result"

# Test 8: Missing accessToken key
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
echo '{"claudeAiOauth":{"refreshToken":"some-refresh"}}' > "$HOME/.claude/.credentials.json"
PATH="$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "missing accessToken key returns failure" "1" "$result"

echo ""
echo "=== macOS Keychain Fallback Tests ==="

# Create a mock `security` command that simulates macOS Keychain
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

# Test 9: Keychain fallback when no credentials file exists
rm -f "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
cat > "$MOCK_BIN/security" << 'MOCK'
#!/usr/bin/env bash
# Mock macOS security command
if [ "$1" = "find-generic-password" ] && [ "$3" = "Claude Code-credentials" ] && [ "$4" = "-w" ]; then
    echo '{"claudeAiOauth":{"accessToken":"keychain-token-abc"}}'
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCK_BIN/security"
token=$(PATH="$MOCK_BIN:$CLEAN_PATH" cu_resolve_token)
assert_eq "keychain fallback reads token" "keychain-token-abc" "$token"

# Test 10: Credentials file takes priority over keychain
mkdir -p "$HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"file-token"}}' > "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
token=$(PATH="$MOCK_BIN:$CLEAN_PATH" cu_resolve_token)
assert_eq "credentials file takes priority over keychain" "file-token" "$token"

# Test 11: Keychain with empty accessToken returns failure
rm -f "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
cat > "$MOCK_BIN/security" << 'MOCK'
#!/usr/bin/env bash
if [ "$1" = "find-generic-password" ] && [ "$3" = "Claude Code-credentials" ] && [ "$4" = "-w" ]; then
    echo '{"claudeAiOauth":{"accessToken":""}}'
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCK_BIN/security"
PATH="$MOCK_BIN:$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "keychain with empty token returns failure" "1" "$result"

# Test 12: Keychain with malformed JSON returns failure
cat > "$MOCK_BIN/security" << 'MOCK'
#!/usr/bin/env bash
if [ "$1" = "find-generic-password" ] && [ "$3" = "Claude Code-credentials" ] && [ "$4" = "-w" ]; then
    echo 'not valid json'
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCK_BIN/security"
PATH="$MOCK_BIN:$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "keychain with malformed JSON returns failure" "1" "$result"

# Test 13: Keychain command fails (item not found) -> overall failure
rm -f "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
cat > "$MOCK_BIN/security" << 'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$MOCK_BIN/security"
PATH="$MOCK_BIN:$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "keychain lookup failure returns failure" "1" "$result"

# Test 14: No security command and no credentials file -> failure
rm -f "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR 2>/dev/null || true
PATH="$CLEAN_PATH" cu_resolve_token >/dev/null && result=0 || result=$?
assert_eq "no security command and no creds file returns failure" "1" "$result"

echo ""
echo "=== cu_extract_piped_usage Tests (CC v2.1.80+ stdin path) ==="

out=$(cu_extract_piped_usage '{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1778580000},"seven_day":{"used_percentage":19,"resets_at":1779100000}}}')
assert_eq "translates five_hour pct" "42" "$(echo "$out" | jq -r '.five_hour.utilization')"
assert_eq "translates seven_day pct" "19" "$(echo "$out" | jq -r '.seven_day.utilization')"
assert_eq "unix epoch -> iso resets_at" "2026-05-12T10:00:00Z" "$(echo "$out" | jq -r '.five_hour.resets_at')"

out=$(cu_extract_piped_usage '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":null}}}')
assert_eq "null resets_at stays null" "null" "$(echo "$out" | jq -r '.five_hour.resets_at')"
assert_eq "absent seven_day -> null" "null" "$(echo "$out" | jq -r '.seven_day')"

cu_extract_piped_usage '{"workspace":{"current_dir":"/tmp"}}' >/dev/null && result=0 || result=$?
assert_eq "no rate_limits returns failure" "1" "$result"

cu_extract_piped_usage '' >/dev/null && result=0 || result=$?
assert_eq "empty input returns failure" "1" "$result"

echo ""
echo "=== cu_write_cache Tests ==="
export CU_CACHE_DIR="$TEST_DIR/write-cache"
CU_CACHE_FILE="${CU_CACHE_DIR}/api-response.json"
CU_BACKOFF_FILE="${CU_CACHE_DIR}/rate-limit-backoff"
mkdir -p "$CU_CACHE_DIR"
echo 1800 > "$CU_BACKOFF_FILE"

cu_write_cache '{"five_hour":{"utilization":7}}'
assert_eq "writes payload to cache file" "7" "$(jq -r '.five_hour.utilization' "$CU_CACHE_FILE")"
[ -f "$CU_BACKOFF_FILE" ] && result=present || result=absent
assert_eq "clears backoff file" "absent" "$result"

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
