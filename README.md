<p align="center">
  <code>claude-usage-statusline</code>
</p>

<p align="center">
  <strong>Know your Claude usage before you hit the wall.</strong>
</p>

<p align="center">
  <a href="https://github.com/meros/claude-usage-statusline/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://github.com/meros/claude-usage-statusline"><img src="https://img.shields.io/badge/shell-bash-green" alt="Shell: bash"></a>
  <a href="https://github.com/meros/claude-usage-statusline/blob/main/flake.nix"><img src="https://img.shields.io/badge/Nix-flake-blue?logo=nixos&logoColor=white" alt="Nix flake"></a>
</p>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#usage">Usage</a> •
  <a href="#claude-code-integration">Claude Code</a> •
  <a href="#flags">Flags</a>
</p>

---

## Why?

Claude Code doesn't show how much of your usage limit you've burned until you're already rate-limited. By then it's too late to pace yourself. This tool puts live usage in your statusline so you always know where you stand.

## What it looks like

**Multi-line** (`--multiline`) — columns align across windows:
```
myproject  main
5h ██░░░░░░░░  35%  .:.. ..::: 11%/1h ~6h 13m  ↻ 5m
7d ████░░░░░░  39%       :..::: 17%/1d ~Fri 9am ↻ Fri 6am
```

**Single-line** (default):
```
myproject  main | 5h: 35% .:.. 11%/1h ~6h 13m ↻ 5m | 7d: 39% :..::: 17%/1d ~Fri 9am ↻ Fri 6am
```

**Dashboard** (`claude-usage show`):
```
Claude Usage
============

5-Hour Window
  ████████░░░░░░░░░░░░  38%    resets in 2h 14m

7-Day Window
  ████████████████░░░░  78%    resets Fri 6am

  Hourly (last 7 days):
  ▁▁▂▂▃▃▅▅██▅▅▃▃▂▂▁▁▂▂▃▃▄▄▅▅▆▆▇▇████▇▇▅▅▃▃

Projection: +4.2%/h | ~Fri 3pm to 100% | BEFORE RESET
```

Colors are Gruvbox-inspired: green (<50%), yellow (50-80%), red (>80%). Rates are orange, ETAs are aqua, sparklines and reset icons are purple, labels and reset times are dim.

## Features

- **5-hour and 7-day windows** — color-coded usage with reset countdown
- **Column-aligned multiline** — progress bars, sparklines, rates, ETAs, and resets align across windows
- **Smart ETA format** — 5h window shows duration (`~6h 13m`), 7d window shows date (`~Fri 9am`)
- **Dual-tier history** — short tier (5-min intervals, 24h) for session tracking, long tier (hourly, 1yr) for weekly trends
- **Sparkline trends** — standard blocks (`▁▂▃▄▅▆▇█`) or compact Braille mode
- **ETA projection** — predicts when you'll hit 100%, warns if before reset
- **Rich dashboard** — full terminal view with `claude-usage show`
- **Configurable modules** — choose which info to show and in what order
- **Update notifications** — see when a new version is available
- **Auto-migration** — seamlessly upgrades from old single-file history
- **XDG-compliant** — respects `XDG_DATA_HOME` and `XDG_CACHE_HOME`

## Install

```bash
nix profile install github:meros/claude-usage-statusline
```

<details>
<summary>Other methods</summary>

**Run without installing:**
```bash
nix run github:meros/claude-usage-statusline
```

**Add to a flake:**
```nix
{
  inputs.claude-usage-statusline.url = "github:meros/claude-usage-statusline";
}
```

**Git clone** (requires `jq`, `curl`, `awk`):
```bash
curl -fsSL https://raw.githubusercontent.com/meros/claude-usage-statusline/main/install.sh | bash
```

</details>

## Usage

```bash
claude-usage                # full dashboard (default)
claude-usage fetch          # force-refresh from API
claude-usage sparkline      # sparkline string only (--tier short|long)
claude-usage eta            # ETA projection for all windows
claude-usage history        # dump raw JSONL (--tier short|long)
claude-usage install-hook   # configure Claude Code statusline
```

## Claude Code Integration

One command to wire it up:

```bash
claude-usage install-hook
```

This sets `statusLine.command` in `~/.claude/settings.json`. Restart Claude Code and usage appears in your statusline.

For multi-line mode with progress bars:

```bash
# Edit ~/.claude/settings.json manually, or:
claude-usage install-hook  # then append --multiline to the command
```

History builds passively — every statusline refresh records a snapshot. The short tier (5-min intervals) tracks session usage for responsive ETA projections, while the long tier (hourly) captures weekly trends.

## Configuration

Everything is configurable via `CU_`-prefixed environment variables. Set them in your shell profile or directly in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "command": "CU_MODULES=pct,eta CU_WINDOWS=five_hour claude-usage statusline"
  }
}
```

### Modules — `CU_MODULES`

Controls which information modules appear and in what order.

| Module | Description |
|--------|-------------|
| `bar` | Progress bar (multiline only, silently skipped in single-line) |
| `pct` | Color-coded percentage |
| `sparkline` | Braille or block sparkline from history |
| `rate` | Burn rate per moving average window |
| `eta` | Time to cap (duration for 5h, date for 7d) |
| `reset` | Reset countdown (5h) or reset date (7d) with ↻ icon |

Defaults: `pct,sparkline,rate,eta,reset` (single-line), `bar,pct,sparkline,rate,eta,reset` (multiline).

### Windows — `CU_WINDOWS`

Controls which API limit windows are displayed.

```bash
CU_WINDOWS="five_hour,seven_day"   # default: both
CU_WINDOWS="five_hour"              # session limit only
CU_WINDOWS="seven_day"              # weekly limit only
```

### Colors — `CU_COLOR_*`

Override any color with a custom ANSI code:

| Variable | Default | Description |
|----------|---------|-------------|
| `CU_COLOR_SPARKLINE` | purple | Sparkline characters |
| `CU_COLOR_RATE` | orange | Burn rate text |
| `CU_COLOR_ETA` | aqua | ETA duration/date |
| `CU_COLOR_RESET` | dim | Reset value text |
| `CU_COLOR_RESET_ICON` | purple | Reset icon (↻) |
| `CU_COLOR_LABEL` | dim | Window labels (5h/7d) |
| `CU_COLOR_DIR` | aqua | Directory name |
| `CU_COLOR_BRANCH` | green | Git branch |
| `CU_COLOR_WARN` | red | Before-reset warning |

Example: `CU_COLOR_RATE="38;2;255;0;0"` for red rate text.

### Other settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CU_SPARKLINE_TYPE` | `braille` | `braille` (compact) or `block` (classic ▁▂▃▄▅▆▇█) |
| `CU_BAR_WIDTH` | `10` | Progress bar width (multiline only) |
| `CU_ETA_5H_AVG` | `1` | Moving average window for 5h ETA (hours) |
| `CU_ETA_7D_AVG` | `24` | Moving average window for 7d ETA (hours) |
| `CU_UPDATE_CHECK` | `1` | Enable update notification (`0` to disable) |
| `CU_UPDATE_TTL` | `3600` | Update check cache TTL in seconds |

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--no-color` | | Disable ANSI colors |
| `--no-fetch` | | Use cached data only, skip API call |
| `--data-dir PATH` | `~/.local/share/claude-usage` | Override history directory |
| `--cache-dir PATH` | `~/.cache/claude-usage` | Override cache directory |
| `--width N` | `40` | Sparkline/progress bar width |
| `--hours N` | `168` | History window in hours |
| `--braille` | | Compact Braille sparkline (2 data points per char) |
| `--multiline` | | Multi-line statusline with progress bars |
| `--windows LIST` | `five_hour,seven_day` | Comma-separated windows to show |
| `--modules LIST` | per mode | Comma-separated modules to show |
| `--sparkline-type TYPE` | `braille` | `braille` or `block` |
| `--bar-width N` | `10` | Progress bar width (multiline) |
| `--tier T` | | History tier: `short` (5-min, 24h) or `long` (hourly, 1yr) |

## Data

| File | Location | Retention |
|------|----------|-----------|
| API cache | `$XDG_CACHE_HOME/claude-usage/api-response.json` | 5-minute TTL |
| Short history | `$XDG_DATA_HOME/claude-usage/history-short.jsonl` | 24 hours, 5-min intervals (`five_hour` field) |
| Long history | `$XDG_DATA_HOME/claude-usage/history-long.jsonl` | 1 year, hourly intervals (`seven_day` field) |

On first run, any existing `history.jsonl` is automatically migrated to the dual-tier format (backup saved as `history.jsonl.bak`).

## Testing

```bash
bash tests/run-tests.sh
```

All rendering, history, and ETA calculations are testable with fixture data via `CU_NOW`, `CU_DATA_DIR`, and `CU_CACHE_DIR` overrides.

## Contributing

Issues and PRs welcome. The codebase is pure bash with no build step — `bin/claude-usage` sources `lib/*.sh` and `views/*.sh`.

## License

[MIT](LICENSE)
