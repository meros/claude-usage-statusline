#!/usr/bin/env bash
# setup.sh - Isolated environment for a unit test suite
#
# Source it at the top of a suite. It creates a temporary HOME, data and cache
# directory (removed on exit), fixes the clock zone, turns colors and the
# update check off, then loads every module and the assertions.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
export CU_DATA_DIR="$TEST_DIR/data"
export CU_CACHE_DIR="$TEST_DIR/cache"
export CU_NO_COLOR=1
export CU_UPDATE_CHECK=0
export CU_TASK_ENABLED=0
export TZ=Europe/Stockholm
unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL CU_NO_LIMITS CU_HIDE_LIMITS NO_COLOR
mkdir -p "$HOME"

CU_LIB_DIR="${REPO_DIR}/lib"
# shellcheck source=../../lib/load.sh
source "${CU_LIB_DIR}/load.sh"
# shellcheck source=assert.sh
source "${TESTS_DIR}/lib/assert.sh"
