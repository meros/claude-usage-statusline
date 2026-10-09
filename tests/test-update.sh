#!/usr/bin/env bash
# test-update.sh - "Update available" notice
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/setup.sh"

CU_UPDATE_CHECK=1

echo "=== Update Message ==="
assert_eq "no cache -> no notice" "" "$(cu_update_message)"

echo '{"available":0}' > "$CU_UPDATE_CACHE"
assert_eq "up to date -> no notice" "" "$(cu_update_message)"

echo '{"available":1}' > "$CU_UPDATE_CACHE"
rm -f "$CU_SESSION_FILE"
assert_eq "new session shows notice" "↑ Update available" "$(CU_NOW=1000 cu_update_message)"
assert_eq "session start recorded" "1000" "$(cat "$CU_SESSION_FILE")"
assert_eq "still shown at 15s" "↑ Update available" "$(CU_NOW=1015 cu_update_message)"
assert_eq "hidden after 15s" "" "$(CU_NOW=1016 cu_update_message)"
assert_eq "new session after 5 min idle" "↑ Update available" "$(CU_NOW=1400 cu_update_message)"
assert_eq "CU_UPDATE_CHECK=0 hides it" "" "$(CU_NOW=1400 CU_UPDATE_CHECK=0 cu_update_message)"

echo ""
echo "=== Background Check ==="
# A local "origin" one commit ahead of the clone.
git init -q -b main "$TEST_DIR/origin"
git -C "$TEST_DIR/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git clone -q "$TEST_DIR/origin" "$TEST_DIR/clone"
git -C "$TEST_DIR/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
rm -f "$CU_UPDATE_CACHE"
CU_NOW=$(date +%s) cu_update_check_bg "$TEST_DIR/clone"
for _ in $(seq 50); do [ -s "$CU_UPDATE_CACHE" ] && break; sleep 0.1; done
assert_eq "detects a newer origin/main" "1" "$(jq -r .available "$CU_UPDATE_CACHE" 2>/dev/null)"

rm -f "$CU_UPDATE_CACHE"
cu_update_check_bg "$TEST_DIR/not-a-repo"
sleep 0.2
[ -f "$CU_UPDATE_CACHE" ] && result=written || result=none
assert_eq "no .git -> no check" "none" "$result"

assert_done
