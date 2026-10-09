#!/usr/bin/env bash
# shellcheck disable=SC2016  # mock scripts in single quotes
# test-fetch.sh - Credential resolution tests
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"
export CU_NOW=1709100000

# PATH without any real `security` command (macOS Keychain); the Keychain
# tests add a mock.
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "^$" | while read -r p; do
    [ -x "$p/security" ] || printf '%s:' "$p"
done)
CLEAN_PATH="${CLEAN_PATH%:}"

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
make_mock "$MOCK_BIN/security" << 'MOCK'
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
make_mock "$MOCK_BIN/security" << 'MOCK'
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
make_mock "$MOCK_BIN/security" << 'MOCK'
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
make_mock "$MOCK_BIN/security" << 'MOCK'
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
CU_CACHE_DIR="$TEST_DIR/write-cache"
cu_set_paths
echo 1800 > "$CU_BACKOFF_FILE"

cu_write_cache '{"five_hour":{"utilization":7}}'
assert_eq "writes payload to cache file" "7" "$(jq -r '.five_hour.utilization' "$CU_CACHE_FILE")"
[ -f "$CU_BACKOFF_FILE" ] && result=present || result=absent
assert_eq "clears backoff file" "absent" "$result"

touch -d "-10 minutes" "$CU_CACHE_FILE.tmp.111"
touch "$CU_CACHE_FILE.tmp.222"
cu_write_cache '{"five_hour":{"utilization":8}}'
[ -f "$CU_CACHE_FILE.tmp.111" ] && result=present || result=absent
assert_eq "removes stale temp files" "absent" "$result"
[ -f "$CU_CACHE_FILE.tmp.222" ] && result=present || result=absent
assert_eq "keeps a temp file another process is writing" "present" "$result"

echo ""
echo "=== cu_fetch Tests (mocked API) ==="

# A fake curl prints $MOCK_RESPONSE and logs each call.
FETCH_DIR="$TEST_DIR/fetch"
CU_CACHE_DIR="$FETCH_DIR/cache"
cu_set_paths
mkdir -p "$HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"tok"}}' > "$HOME/.claude/.credentials.json"
unset CLAUDE_CONFIG_DIR
CU_NOW=$(date +%s)  # cache freshness compares file mtimes with "now"
printf 'echo call >> "%s/curl-calls"\nprintf "%%s" "$MOCK_RESPONSE"\n' "$FETCH_DIR" | make_mock "$MOCK_BIN/curl"
chmod +x "$MOCK_BIN/curl"
FETCH_PATH="$MOCK_BIN:$CLEAN_PATH"
calls() { wc -l < "$FETCH_DIR/curl-calls" 2>/dev/null | tr -d ' ' || echo 0; }

export MOCK_RESPONSE='{"five_hour":{"utilization":12,"resets_at":"2025-03-01T14:00:00Z"},"seven_day":{"utilization":40,"resets_at":null}}'
PATH="$FETCH_PATH" cu_fetch && result=0 || result=$?
assert_eq "successful fetch returns 0" "0" "$result"
assert_eq "successful fetch writes the cache" "12" "$(cu_get_five_hour_pct)"
assert_eq "one API call" "1" "$(calls)"

PATH="$FETCH_PATH" cu_fetch
assert_eq "fresh cache skips the API" "1" "$(calls)"

PATH="$FETCH_PATH" cu_fetch force
assert_eq "force ignores the fresh cache" "2" "$(calls)"

# Rate limit: backoff starts at CU_CACHE_MAX_AGE and doubles up to 30 min.
touch -d "@$((CU_NOW - 3600))" "$CU_CACHE_FILE"
export MOCK_RESPONSE='{"error":{"type":"rate_limit_error","message":"Rate limited"}}'
PATH="$FETCH_PATH" cu_fetch 2>/dev/null && result=0 || result=$?
assert_eq "rate-limited fetch returns 1" "1" "$result"
assert_eq "first backoff is the cache TTL" "300" "$(cat "$CU_BACKOFF_FILE")"
assert_eq "stale cache data is kept" "12" "$(cu_get_five_hour_pct)"

before=$(calls)
PATH="$FETCH_PATH" cu_fetch 2>/dev/null || true
assert_eq "no API call during backoff" "$before" "$(calls)"

PATH="$FETCH_PATH" cu_fetch force 2>/dev/null || true
assert_eq "second rate limit doubles the backoff" "600" "$(cat "$CU_BACKOFF_FILE")"
echo 1500 > "$CU_BACKOFF_FILE"
PATH="$FETCH_PATH" cu_fetch force 2>/dev/null || true
assert_eq "backoff is capped at 1800s" "1800" "$(cat "$CU_BACKOFF_FILE")"

# Rate limit with no cache at all: sentinel with a retry time.
rm -f "$CU_CACHE_FILE" "$CU_BACKOFF_FILE"
PATH="$FETCH_PATH" cu_fetch 2>/dev/null || true
assert_eq "no cache + rate limit writes sentinel" "rate_limited" "$(jq -r '._error' "$CU_CACHE_FILE")"

# Success clears the backoff.
export MOCK_RESPONSE='{"seven_day":{"utilization":41,"resets_at":null}}'
PATH="$FETCH_PATH" cu_fetch force
[ -f "$CU_BACKOFF_FILE" ] && result=present || result=absent
assert_eq "success clears the backoff" "absent" "$result"
assert_eq "seven_day-only response accepted" "41" "$(cu_get_seven_day_pct)"

# Garbage and empty responses fail without touching the cache.
export MOCK_RESPONSE='<html>bad gateway</html>'
PATH="$FETCH_PATH" cu_fetch force 2>/dev/null && result=0 || result=$?
assert_eq "unexpected response returns 1" "1" "$result"
assert_eq "unexpected response keeps the cache" "41" "$(cu_get_seven_day_pct)"
export MOCK_RESPONSE=''
PATH="$FETCH_PATH" cu_fetch force 2>/dev/null && result=0 || result=$?
assert_eq "empty response returns 1" "1" "$result"

# No flock (macOS default): fetch still works, unlocked.
NOFLOCK_BIN="$TEST_DIR/noflock-bin"
mkdir -p "$NOFLOCK_BIN"
for tool in bash jq cat date stat tail tr mv rm mkdir awk wc; do
    ln -sf "$(command -v "$tool")" "$NOFLOCK_BIN/$tool"
done
export MOCK_RESPONSE='{"five_hour":{"utilization":13,"resets_at":null}}'
PATH="$MOCK_BIN:$NOFLOCK_BIN" cu_fetch force && result=0 || result=$?
assert_eq "fetch works without flock" "0" "$result"
assert_eq "fetch without flock writes the cache" "13" "$(cu_get_five_hour_pct)"

echo ""
echo "=== Cache Field Accessors ==="
data='{"five_hour":{"utilization":7.5,"resets_at":"2025-03-01T14:00:00Z"},"seven_day":{"utilization":42,"resets_at":"2025-03-06T00:00:00Z"}}'
assert_eq "five_hour pct" "7.5" "$(cu_get_five_hour_pct "$data")"
assert_eq "seven_day reset" "2025-03-06T00:00:00Z" "$(cu_get_seven_day_reset "$data")"
assert_eq "missing window is empty" "" "$(cu_usage_field five_hour utilization '{"seven_day":{}}')"

assert_done
