#!/bin/bash
# TokenMaccer installer: collector + launchd job + (optionally) builds and installs the widget app.
#
#   ./install.sh                     collector and app (signing team is detected or asked for)
#   ./install.sh --collector-only    only the collector and its launchd job
#
# Environment: DEVELOPMENT_TEAM=ABCDE12345  BUNDLE_ID_PREFIX=com.yourname
set -euo pipefail

LABEL="tokenmaccer.collector"
DATA_DIR="$HOME/.claude/tools/tokenmaccer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DIR="$HOME/Applications"
REPO="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --collector-only) COLLECTOR_ONLY=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "macOS only."
/usr/bin/python3 -c pass >/dev/null 2>&1 || die "Python 3 is not available. Install the Command Line Tools: xcode-select --install"
[ -d "$HOME/.claude" ] || echo "note: ~/.claude not found yet; the collector will pick up transcripts once Claude Code has run."

# --- collector ---
say "Installing collector to $DATA_DIR"
mkdir -p "$DATA_DIR" "$HOME/Library/LaunchAgents"
install -m 0644 "$REPO/collector/collector.py" "$DATA_DIR/collector.py"
if [ -f "$DATA_DIR/prices.json" ] && ! cmp -s "$REPO/collector/prices.json" "$DATA_DIR/prices.json"; then
  cp "$DATA_DIR/prices.json" "$DATA_DIR/prices.json.bak"
  echo "    existing prices.json saved as prices.json.bak"
fi
install -m 0644 "$REPO/collector/prices.json" "$DATA_DIR/prices.json"

say "Registering launchd job $LABEL (every 5 minutes)"
# Pass custom transcript locations set at install time on to launchd
ENV_XML=""
for var in CLAUDE_CONFIG_DIR TOKENMACCER_EXTRA_SOURCES; do
  val="${!var:-}"
  [ -n "$val" ] && ENV_XML="$ENV_XML    <key>$var</key><string>$val</string>
"
done
[ -n "$ENV_XML" ] && ENV_XML="  <key>EnvironmentVariables</key>
  <dict>
$ENV_XML  </dict>
"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>-I</string>
    <string>$DATA_DIR/collector.py</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$DATA_DIR/collector.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/collector.log</string>
$ENV_XML</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

say "First collector run (reads all existing transcripts, may take a minute)"
/usr/bin/python3 -I "$DATA_DIR/collector.py"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

if [ "$COLLECTOR_ONLY" = 1 ]; then
  say "Done (collector only). Data: $DATA_DIR/widget.json"
  exit 0
fi

# --- app ---
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at $DEVELOPER_DIR. Install Xcode 16 or newer, or run with --collector-only."
command -v xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"

if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  # Team ID = OU of the "Apple Development" certificate(s) in the keychain
  TEAMS=$( { security find-certificate -a -c "Apple Development" -p 2>/dev/null || true; } \
    | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{print c | "openssl x509 -noout -subject"; close("openssl x509 -noout -subject")}' \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort -u)
  COUNT=$(printf '%s' "$TEAMS" | grep -c . || true)
  if [ "$COUNT" = 1 ]; then
    DEVELOPMENT_TEAM="$TEAMS"
    echo "    using signing team $DEVELOPMENT_TEAM (from your Apple Development certificate)"
  else
    [ "$COUNT" = 0 ] && echo "No \"Apple Development\" certificate found. Sign in with your Apple ID in Xcode > Settings > Accounts and create one (free)."
    [ "$COUNT" -gt 1 ] && printf 'Several teams found:\n%s\n' "$TEAMS"
    read -r -p "Team ID (10 characters): " DEVELOPMENT_TEAM || die "no team ID given. The collector is installed and running; build the app later with DEVELOPMENT_TEAM=ABCDE12345 ./install.sh"
  fi
fi
[[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "invalid team ID: $DEVELOPMENT_TEAM"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-local.$(id -un | tr -cd 'a-zA-Z0-9')}"

say "Building TokenMaccer.app (team $DEVELOPMENT_TEAM, bundle id $BUNDLE_ID_PREFIX.tokenmaccer)"
cd "$REPO/app"
xcodegen generate --quiet
# Builds go to build.noindex: Spotlight skips *.noindex folders, so the build copy never shows up as a second
# TokenMaccer in the widget gallery or in Open With. Older versions built into app/build; remove that copy.
if [ -d build ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$REPO/app/build/Build/Products/Release/TokenMaccer.app" 2>/dev/null || true
  rm -rf build
fi
xcodebuild -project TokenMaccer.xcodeproj -scheme TokenMaccer -configuration Release \
  -derivedDataPath build.noindex DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" BUNDLE_ID_PREFIX="$BUNDLE_ID_PREFIX" \
  -quiet build

say "Installing to $APP_DIR/TokenMaccer.app"
mkdir -p "$APP_DIR"
# Stop the app and the running widget extension, otherwise the desktop keeps the old code in memory
pkill -x TokenMaccer 2>/dev/null || true
pkill -x TokenMaccerWidget 2>/dev/null || true
rm -rf "$APP_DIR/TokenMaccer.app"
cp -R build.noindex/Build/Products/Release/TokenMaccer.app "$APP_DIR/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$REPO/app/build.noindex/Build/Products/Release/TokenMaccer.app" 2>/dev/null || true
open "$APP_DIR/TokenMaccer.app"

say "Done. Add the widget: right-click the desktop > Edit Widgets... > search \"TokenMaccer\"."
