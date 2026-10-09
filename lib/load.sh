#!/usr/bin/env bash
# load.sh - Source every module in dependency order
#
# Usage: CU_LIB_DIR=<lib dir> CU_VIEWS_DIR=<views dir> source load.sh
# bin/claude-usage and the tests both load the code through this file.

: "${CU_LIB_DIR:?CU_LIB_DIR must point at the lib directory}"
: "${CU_VIEWS_DIR:=${CU_LIB_DIR}/../views}"

# shellcheck source=util.sh
source "${CU_LIB_DIR}/util.sh"      # paths, clock, colors, formatting
# shellcheck source=config.sh
source "${CU_LIB_DIR}/config.sh"    # CU_* settings, window definitions
# shellcheck source=fetch.sh
source "${CU_LIB_DIR}/fetch.sh"     # API, cache, backoff, stdin rate_limits
# shellcheck source=history.sh
source "${CU_LIB_DIR}/history.sh"   # two-tier JSONL history
# shellcheck source=eta.sh
source "${CU_LIB_DIR}/eta.sh"       # burn rate, flat and seasonal ETA
# shellcheck source=render.sh
source "${CU_LIB_DIR}/render.sh"    # sparklines, bars, value formatting
# shellcheck source=pace.sh
source "${CU_LIB_DIR}/pace.sh"      # work-week budget pacing
# shellcheck source=task.sh
source "${CU_LIB_DIR}/task.sh"      # per-session task label
# shellcheck source=update.sh
source "${CU_LIB_DIR}/update.sh"    # update notice
# shellcheck source=cli.sh
source "${CU_LIB_DIR}/cli.sh"       # flags, subcommands

# shellcheck source=../views/statusline.sh
source "${CU_VIEWS_DIR}/statusline.sh"
# shellcheck source=../views/dashboard.sh
source "${CU_VIEWS_DIR}/dashboard.sh"
# shellcheck source=../views/history.sh
source "${CU_VIEWS_DIR}/history.sh"
