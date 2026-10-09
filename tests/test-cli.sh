#!/usr/bin/env bash
# test-cli.sh - Command dispatch, flags and install-hook, through bin/claude-usage
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"
source "${TESTS_DIR}/lib/demo.sh"

BIN="${REPO_DIR}/bin/claude-usage"
export CU_NOW="$DEMO_NOW"
demo_build "$CU_DATA_DIR" "$CU_CACHE_DIR"

run() { "$BIN" "$@" 2>&1; }

echo "=== Dispatch ==="
assert_contains "help lists commands" "install-hook" "$(run help)"
assert_contains "--help works" "Usage: claude-usage" "$(run --help)"
assert_status "unknown command fails" 1 "$BIN" frobnicate
assert_contains "unknown command names it" "Unknown command: frobnicate" "$(run frobnicate || true)"
assert_status "unknown flag fails" 1 "$BIN" show --frob
assert_contains "flag without value" "--tier requires" "$(run history --tier || true)"
assert_status "statusline refuses a terminal stdin" 1 script -qec "$BIN statusline" /dev/null
assert_contains "default command is the dashboard" "Claude Usage" "$(run --no-fetch)"
assert_contains "no arguments runs the dashboard" "Claude Usage" "$(run)"

echo ""
echo "=== History ==="
assert_eq "history --tier long dumps the long file" "$(cat "$CU_HISTORY_LONG")" "$(run history --tier long)"
assert_contains "history without tier labels the short tier" "=== Short tier (5-min, 36h) ===" "$(run history)"
assert_status "unknown tier fails" 1 "$BIN" history --tier medium
assert_contains "hv alias" "Recent (5-min intervals" "$(run hv --hours 1)"
empty="$TEST_DIR/empty-data"
assert_contains "history-view without data explains" "No history yet" "$(run history-view --data-dir "$empty" || true)"

echo ""
echo "=== --data-dir / --cache-dir ==="
other="$TEST_DIR/other"
demo_build "$other/data" "$other/cache"
echo '{"five_hour":{"utilization":77,"resets_at":null}}' > "$other/cache/api-response.json"
out=$(run show --no-fetch --no-color --cache-dir "$other/cache" --data-dir "$other/data")
assert_contains "--cache-dir reads that cache" "77%" "$out"

echo ""
echo "=== install-hook ==="
export CLAUDE_CONFIG_DIR="$TEST_DIR/claude"
out=$(run install-hook)
settings="$CLAUDE_CONFIG_DIR/settings.json"
assert_eq "sets the statusline type" "command" "$(jq -r .statusLine.type "$settings")"
assert_eq "sets the command" "$BIN statusline" "$(jq -r .statusLine.command "$settings")"
assert_contains "reports the settings file" "$settings" "$out"

echo '{"theme":"dark","statusLine":{"command":"old"}}' > "$settings"
run install-hook --multiline --modules pct,eta --no-color >/dev/null
assert_eq "keeps display flags" "$BIN statusline --multiline --modules pct,eta" "$(jq -r .statusLine.command "$settings")"
assert_eq "keeps other settings" "dark" "$(jq -r .theme "$settings")"

echo 'not json' > "$settings"
assert_status "invalid settings JSON fails" 1 "$BIN" install-hook
assert_eq "invalid settings are left alone" "not json" "$(cat "$settings")"

# A symlink on PATH that points at this install is preferred over the real path.
mkdir -p "$TEST_DIR/bin"
ln -s "$BIN" "$TEST_DIR/bin/claude-usage"
echo '{}' > "$settings"
PATH="$TEST_DIR/bin:$PATH" "$BIN" install-hook >/dev/null
assert_eq "prefers the PATH entry of the same install" "$TEST_DIR/bin/claude-usage statusline" "$(jq -r .statusLine.command "$settings")"

echo ""
echo "=== Missing dependency ==="
nodeps="$TEST_DIR/nodeps"
mkdir -p "$nodeps"
for tool in bash dirname readlink; do ln -s "$(command -v "$tool")" "$nodeps/$tool"; done
out=$(PATH="$nodeps" "$BIN" show 2>&1 || true)
assert_contains "names the missing tool" "'jq' is required" "$out"

assert_done
