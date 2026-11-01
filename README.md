# TokenMaccer

A macOS desktop widget that shows your **Claude Code** token usage like a stock ticker: today, 7 days, 30 days, year to date, 1 year and all time, with the change against the previous period.

> TokenMaccer is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic.

<p>
  <img src="docs/widget-medium-light.png" width="364" alt="Medium widget, light mode, 30 days">
  <img src="docs/widget-large-dark.png" width="364" alt="Large widget, dark mode, 30 days">
</p>

*Screenshots use made-up demo data.*

## What it shows

- **Input tokens** as the headline (uncached input + cache reads + cache writes), tap to switch to **USD**.
- Stock-chart logic: the line is the running total of the period and ends at the headline number; the dotted line is the previous period on the same axis. The axis always covers the whole period (1D: midnight to midnight), so the line stops at "now".
- Change against the previous period: orange when usage rises, green when it falls. 1D, 7D and 30D compare up to the same time of day, so a half-finished day is not compared with a full one.
- Output tokens, input per output token, and the estimated cost at API list prices.
- Period chips (1D · 7D · 30D · YTD · 1Y · ALL) right in the widget; in the small widget, tap the period name.
- Light, dark, clear and tinted desktop modes.

USD values are estimates at public API list prices (`collector/prices.json`). If you use a subscription plan, they show what the same usage would cost via the API, not what you pay.

## How it works

```
~/.claude/projects/**/*.jsonl ──► collector.py (launchd, every 15 min) ──► ~/.claude/tools/tokenmaccer/widget.json ──► widget
```

- `collector/collector.py` reads Claude Code's local transcripts incrementally (only new bytes), de-duplicates messages and keeps daily totals in `store.json`. Claude Code deletes old transcripts after a while (30 days by default); your history stays in the store, with 14 daily backups.
- The widget is sandboxed and only gets **read** access to `~/.claude/tools/tokenmaccer/`.
- Everything stays on your Mac. No network access, no telemetry.

## Requirements

- macOS 15 or newer
- Xcode 16 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An "Apple Development" signing certificate. A free Apple ID works: Xcode > Settings > Accounts > add your Apple ID > Manage Certificates > "+" > Apple Development. Widgets need a signed app; nothing is uploaded to Apple.

## Install

```sh
git clone https://github.com/valentinherrera/tokenmaccer.git
cd tokenmaccer
./install.sh
```

The installer

1. copies the collector to `~/.claude/tools/tokenmaccer/` and registers a launchd job (`tokenmaccer.collector`, every 15 minutes),
2. runs it once (the first run reads all existing transcripts),
3. builds the app with your signing team (detected from your certificate, or set `DEVELOPMENT_TEAM=ABCDE12345`) and installs it to `~/Applications/TokenMaccer.app`.

Then right-click the desktop, choose **Edit Widgets…** and search for **TokenMaccer**.

Options: `./install.sh --collector-only` skips the app. `BUNDLE_ID_PREFIX=com.yourname ./install.sh` sets your own bundle id prefix.

## Uninstall

```sh
./uninstall.sh           # removes the launchd job and the app, keeps your history
./uninstall.sh --purge   # also deletes ~/.claude/tools/tokenmaccer
```

## Configuration

- **Prices:** edit `~/.claude/tools/tokenmaccer/prices.json` (USD per million tokens). Unknown models use `_fallback`.
- **Custom Claude config dir / extra transcript folders:** set `CLAUDE_CONFIG_DIR` or `TOKENMACCER_EXTRA_SOURCES=/path/one:/path/two` when running `./install.sh`; the installer passes them on to the launchd job.
- **Re-read everything:** `python3 ~/.claude/tools/tokenmaccer/collector.py --rebuild` (keeps days whose transcripts are already gone).

## Development

```sh
python3 -m unittest discover -s tests     # collector tests with made-up transcripts
ruff check . && mypy collector tests       # lint and types

# preview the widget as PNGs with demo data, without installing anything
python3 scripts/make_demo.py /tmp/tm-demo/claude
TOKENMACCER_CLAUDE_DIR=/tmp/tm-demo/claude TOKENMACCER_DATA_DIR=/tmp/tm-demo/data python3 collector/collector.py
xcrun swiftc app/Shared/*.swift app/Preview/main.swift -o /tmp/tm-render
/tmp/tm-render /tmp/tm-demo/data/widget.json /tmp/tm-demo 30D -AppleLocale en_US
```

The collector uses only the Python standard library and runs on the macOS system Python (3.9).

## License

[MIT](LICENSE)
