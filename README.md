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
~/.claude/projects/**/*.jsonl ──► collector.py (launchd, every 5 min) ──► ~/.claude/tools/tokenmaccer/widget.json ──► widget
```

- `collector/collector.py` reads Claude Code's local transcripts incrementally (only new bytes), de-duplicates messages and keeps daily totals in `store.json`. Claude Code deletes old transcripts after a while (30 days by default); your history stays in the store, with 14 daily backups.
- The widget is sandboxed and only gets **read** access to `~/.claude/tools/tokenmaccer/`.
- Everything stays on your Mac. No network access, no telemetry.

## Requirements

| What | Why | How to check / get it |
|---|---|---|
| A Mac with **macOS 15** or newer | WidgetKit APIs used by the widget | Apple menu > About This Mac |
| **Claude Code**, used at least once | The collector reads its local transcripts in `~/.claude/projects` | `ls ~/.claude/projects` |
| **Xcode 16** or newer, opened once | Builds the app; the first launch accepts the license and installs components | `xcodebuild -version` |
| **Command Line Tools** | Provide `/usr/bin/python3` for the collector | `xcode-select -p`, else `xcode-select --install` |
| **Homebrew** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** | Generates the Xcode project from `app/project.yml` | `brew install xcodegen` |
| An **"Apple Development" certificate** | macOS only shows widgets from signed apps | see below |

**Getting the certificate (free, about two minutes):** open Xcode > Settings > Accounts, add your Apple ID, select your team, click **Manage Certificates…**, then **+** > **Apple Development**. A free Apple ID is enough; no paid developer account, nothing is uploaded to Apple. The installer reads your team ID from this certificate.

Without a certificate the installer still sets up the collector and tells you what is missing; run it again once the certificate exists.

**Tested on:** macOS 26 with Xcode 26 (Apple Silicon), full install. CI builds on macOS 15 with Xcode 16. Not yet tested: Intel Macs, running the widget on macOS 15. Reports welcome as issues.

<!-- PENDING RELEASE: draft for the downloadable app. Keep hidden until the GitHub release with the
     notarized DMG exists (decision by the maintainer). Then remove this comment and the closing marker below.

## Download (app)

No Xcode, no Terminal, no Python: the app brings its own collector.

1. Download `TokenMaccer-1.0.0.dmg` from the [latest release](https://github.com/valentinherrera/tokenmaccer/releases/latest) and open it.
2. Drag **TokenMaccer** onto **Applications**, then open it from Applications once. The app is notarized by Apple. macOS asks once to confirm opening an app downloaded from the internet; click **Open**. No security warning appears.
3. The window shows whether your Claude Code transcripts were found and that background updates are on (every 5 minutes, also after a restart). If your transcripts live outside `~/.claude`, click **Choose Folder…**. To also count an archive folder you move old sessions into, add `"extraSources": ["/path/to/archive"]` to `~/Library/Application Support/TokenMaccer/settings.json`.
4. Right-click the desktop › **Edit Widgets…** › search for **TokenMaccer** and add it. Your numbers appear within a few minutes.

Already using the `install.sh` setup? The app takes over your history from `~/.claude/tools/tokenmaccer/` on its first run (it only copies, the old folder stays). Use one of the two, not both: run `./uninstall.sh` once the app shows your numbers.

END PENDING RELEASE -->

## Install with Claude Code

Paste this into Claude Code:

```
Install TokenMaccer from https://github.com/valentinherrera/tokenmaccer: check the requirements in its README, clone it to ~/tokenmaccer and run ./install.sh. If xcodegen is missing, install it with Homebrew. If no Apple Development certificate is found, stop and tell me how to create one.
```

Claude clones the repo, checks the requirements and runs the installer. Creating the certificate in Xcode is the one step you do yourself. Afterwards add the widget (see below).

## Install manually

```sh
git clone https://github.com/valentinherrera/tokenmaccer.git
cd tokenmaccer
./install.sh
```

The installer

1. copies the collector to `~/.claude/tools/tokenmaccer/` and registers a launchd job (`tokenmaccer.collector`, every 5 minutes),
2. runs it once (the first run reads all existing transcripts),
3. builds the app with your signing team (detected from your certificate, or set `DEVELOPMENT_TEAM=ABCDE12345`) and installs it to `~/Applications/TokenMaccer.app`.

Then right-click the desktop, choose **Edit Widgets…** and search for **TokenMaccer**.

Options: `./install.sh --collector-only` skips the app. `BUNDLE_ID_PREFIX=com.yourname ./install.sh` sets your own bundle id prefix. Running `./install.sh` again updates an existing install.

**Note:** macOS decides when a desktop widget redraws. The widget asks for a refresh every 5 minutes, but the actual update can lag a few minutes behind; the app window always shows the latest numbers.

## Uninstall

```sh
./uninstall.sh           # removes the launchd job and the app, keeps your history
./uninstall.sh --purge   # also deletes ~/.claude/tools/tokenmaccer
```

<!-- PENDING RELEASE: applies to the downloadable app; publish together with "Download (app)" above.

### Uninstall the app

1. Remove the widget: right-click it on the desktop › **Remove Widget**.
2. Open TokenMaccer and choose **Stop › Stop Background Updates & Remove Data…**. This removes everything the app wrote, its own settings included, so a later reinstall starts fresh. To keep your history, choose **Stop Background Updates** instead; after a reinstall, click **Turn On** in the TokenMaccer window.
3. Quit TokenMaccer and drag it from Applications to the Trash.

The same in Terminal:

```sh
osascript -e 'quit app "TokenMaccer"'
/Applications/TokenMaccer.app/Contents/MacOS/TokenMaccer --unregister --remove-data   # without --remove-data: keep history
rm -rf /Applications/TokenMaccer.app
```

What the app writes, so you can check: `~/Library/Application Support/TokenMaccer/` (history, settings), `~/Library/Preferences/io.github.valentinherrera.tokenmaccer.plist` (the app's own settings) and `widget.json` plus shared settings in `~/Library/Group Containers/3KM85F22L8.tokenmaccer/`. **Remove Data** (or `--remove-data`) deletes all of these; after the window path macOS may keep the preferences file empty, with no settings in it. Claude Code's transcripts and an `install.sh` setup's `~/.claude/tools/tokenmaccer/` are never touched.

END PENDING RELEASE -->

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
