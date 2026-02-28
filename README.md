# claude-usage-statusline

Monitor your Claude API usage with history tracking, sparkline visualizations, ETA projections, and limit warnings.

## Features

- **5-hour and 7-day usage tracking** with color-coded thresholds
- **Hourly usage history** stored as JSONL (14-day retention)
- **Sparkline visualization** of usage trends
- **ETA projection** — warns when you'll hit the cap before reset
- **Claude Code statusline** integration
- **Rich terminal dashboard**

## Install

### Nix (recommended)

```bash
# Run directly
nix run github:meros/claude-usage-statusline

# Add to flake inputs
{
  inputs.claude-usage-statusline.url = "github:meros/claude-usage-statusline";
}

# Or install imperatively
nix profile install github:meros/claude-usage-statusline
```

### Git clone

```bash
curl -fsSL https://raw.githubusercontent.com/meros/claude-usage-statusline/main/install.sh | bash
```

Requires: `jq`, `curl`, `bc`

## Usage

```bash
# Full dashboard
claude-usage

# Force refresh
claude-usage fetch

# Sparkline only
claude-usage sparkline

# ETA projection
claude-usage eta

# Configure Claude Code statusline
claude-usage install-hook
```

### Claude Code statusline

The `statusline` subcommand reads workspace JSON from stdin (as provided by Claude Code) and outputs a single colored line:

```
myproject  main | 5h: 12% | 7d: 42% resets Mar 6 | ▁▂▃▄▅▃▂▄
```

When projected to hit the limit before reset:
```
myproject  main | 5h: 68% | 7d: 72% resets Mar 6 | ~14h to cap | ▅▆▇▇█▇▆▇
```

### Dashboard

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

Colors: green <50%, yellow 50-80%, red >80%.

## Flags

| Flag | Description |
|------|-------------|
| `--no-color` | Disable color output |
| `--no-fetch` | Skip API fetch, use cached data |
| `--data-dir PATH` | Override data directory |
| `--cache-dir PATH` | Override cache directory |
| `--width N` | Sparkline/bar width |
| `--hours N` | History window in hours |

## Data

- **Cache**: `${XDG_CACHE_HOME:-~/.cache}/claude-usage/api-response.json` (5-min TTL)
- **History**: `${XDG_DATA_HOME:-~/.local/share}/claude-usage/history.jsonl` (14-day retention)

## Testing

```bash
bash tests/run-tests.sh
```

## License

MIT
