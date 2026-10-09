#!/usr/bin/env bash
# screenshots.sh - Render the README screenshots from the demo dataset
#
# Usage: bash scripts/screenshots.sh
#
# Each scene runs bin/claude-usage on the fixed demo data (tests/lib/demo.sh),
# converts the ANSI output to HTML and takes a headless Chrome screenshot into
# docs/<scene>.png. Needs nix (for the Iosevka font, which has every glyph the
# tool prints: braille, ↻, blocks) and Chrome or Chromium; set CHROME to pick
# the binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/docs"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CHROME="${CHROME:-$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)}"
[ -n "$CHROME" ] || { echo "Chrome or Chromium is required (set CHROME)" >&2; exit 1; }

# Fontconfig that adds Iosevka to the system fonts, for Chrome only.
FONT_DIR=$(nix build --no-link --print-out-paths nixpkgs#iosevka-bin)/share/fonts
cat > "$WORK/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <dir>${FONT_DIR}</dir>
  <cachedir>${WORK}/fontcache</cachedir>
</fontconfig>
EOF

# shellcheck source=../tests/lib/demo.sh
source "${ROOT}/tests/lib/demo.sh"
# shellcheck source=../lib/util.sh
CU_DATA_DIR="$WORK/x" CU_CACHE_DIR="$WORK/x" source "${ROOT}/lib/util.sh"  # cu_visible_len

PROJECT="$WORK/myproject"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q -b main

# Run claude-usage on a fresh copy of the demo data; print its ANSI output.
# Usage: scene ARGS... (env assignments before "--" apply to the run)
scene() {
    local home="$WORK/home"
    rm -rf "$home"
    mkdir -p "$home/state"
    demo_build "$home/data" "$home/cache"
    echo "[api] fix login redirect" > "$home/state/pid-4242"
    echo "2/5 tests ~15m" > "$home/state/progress-4242"

    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    local stdin=""
    [ "$1" = statusline ] && stdin=$(demo_stdin "$PROJECT")
    env HOME="$home" TZ=Europe/Stockholm LC_ALL=C.UTF-8 CU_NOW="$DEMO_NOW" CU_UPDATE_CHECK=0 \
        CU_DATA_DIR="$home/data" CU_CACHE_DIR="$home/cache" \
        CU_TASK_PID=4242 CU_TASK_STATE_DIR="$home/state" CU_TASK_HELPER=/nonexistent \
        ${envs[@]+"${envs[@]}"} "${ROOT}/bin/claude-usage" "$@" <<< "$stdin"
}

# ANSI SGR (24-bit foreground and reset only, which is all the tool emits) to HTML.
ansi_to_html() {
    sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
        -e 's/\x1b\[38;2;\([0-9]*\);\([0-9]*\);\([0-9]*\)m/<\/span><span style="color:rgb(\1,\2,\3)">/g' \
        -e 's/\x1b\[0m/<\/span>/g'
}

# shot NAME ANSI_FILE - write docs/NAME.png
shot() {
    local name="$1" ansi="$2"
    local cols=0 lines=0 line len
    while IFS= read -r line || [ -n "$line" ]; do
        len=$(cu_visible_len "$line")
        [ "$len" -gt "$cols" ] && cols=$len
        lines=$((lines + 1))
    done < "$ansi"

    # 15px Iosevka is 7.5px wide (8 leaves slack); 21px lines; 22px padding.
    local width=$(( cols * 8 + 44 )) height=$(( lines * 21 + 44 ))
    {
        printf '<!doctype html><meta charset="utf-8"><style>'
        printf 'html,body{margin:0;background:#282828}'
        printf 'pre{margin:0;padding:22px;font:15px/21px Iosevka,monospace;color:#ebdbb2;font-variant-ligatures:none}'
        printf '</style><pre>'
        ansi_to_html < "$ansi"
        printf '</pre>'
    } > "$WORK/$name.html"

    FONTCONFIG_FILE="$WORK/fonts.conf" "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
        --force-device-scale-factor=2 --window-size="$width,$height" \
        --user-data-dir="$WORK/chrome" \
        --screenshot="$OUT/$name.png" "file://$WORK/$name.html" >/dev/null 2>&1
    echo "wrote docs/$name.png (${cols}x${lines})"
}

mkdir -p "$OUT"
scene -- statusline --multiline > "$WORK/multiline.ansi"
shot statusline-multiline "$WORK/multiline.ansi"
scene -- statusline > "$WORK/single.ansi"
shot statusline-single "$WORK/single.ansi"
scene CU_SPARKLINE_TYPE=block -- statusline --multiline > "$WORK/block.ansi"
shot statusline-block "$WORK/block.ansi"
scene -- show --no-fetch > "$WORK/dashboard.ansi"
shot dashboard "$WORK/dashboard.ansi"
scene -- history-view --no-fetch --hours 1 > "$WORK/history.ansi"
shot history-view "$WORK/history.ansi"
