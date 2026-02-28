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

**Single-line** (default):
```
myproject  main | 5h: 12% | 7d: 42% resets Mar 6 | ▁▂▃▄▅▃▂▄
```

**Multi-line** (`--multiline`):
```
myproject  main
5h ████████░░ 38% ↻ 2h 14m  7d ██████████████████░░ 78% ↻ Mar 6
▁▂▃▄▅▃▂▄▅▆▇▆▇  ~1d 3h to cap
```

**Dashboard** (`claude-usage show`):
```
Claude Usage
============

5-Hour Window
  ████████░░░░░░░░░░░░  38%    resets in 2h 14m

7-Day Window
  ████████████████░░░░  78%    resets Mar 6 (5d 3h)

  Hourly (last 7 days):
  ▁▁▂▂▃▃▅▅██▅▅▃▃▂▂▁▁▂▂▃▃▄▄▅▅▆▆▇▇████▇▇▅▅▃▃

Projection: +4.2%/h | ~1d 3h to 100% | BEFORE RESET
```

Colors: green <50%, yellow 50-80%, red >80%. Gruvbox palette.

## Features

- **5-hour and 7-day windows** — color-coded usage with reset countdown
- **Hourly history** — JSONL with 14-day retention, deduplicated per hour
- **Sparkline trends** — standard blocks (`▁▂▃▄▅▆▇█`) or compact Braille mode
- **ETA projection** — predicts when you'll hit 100%, warns if before reset
- **Multi-line statusline** — progress bars, sparkline, and ETA in your Claude Code status
- **Rich dashboard** — full terminal view with `claude-usage show`
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
claude-usage sparkline      # sparkline string only
claude-usage eta            # ETA projection
claude-usage history        # dump raw JSONL
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

History builds passively — every statusline refresh records a snapshot (deduplicated to one per hour).

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

## Data

| File | Location | Retention |
|------|----------|-----------|
| API cache | `$XDG_CACHE_HOME/claude-usage/api-response.json` | 5-minute TTL |
| History | `$XDG_DATA_HOME/claude-usage/history.jsonl` | 14 days, hourly |

## Testing

```bash
bash tests/run-tests.sh
```

All rendering, history, and ETA calculations are testable with fixture data via `CU_NOW`, `CU_DATA_DIR`, and `CU_CACHE_DIR` overrides.

## Contributing

Issues and PRs welcome. The codebase is pure bash with no build step — `bin/claude-usage` sources `lib/*.sh` and `views/*.sh`.

## License

[MIT](LICENSE)
