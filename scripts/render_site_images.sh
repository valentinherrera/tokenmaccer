#!/bin/bash
# Renders the website pictures (docs/assets) from fixtures and demo data, with a transparent background: the page draws
# the Liquid Glass panel behind each picture itself (CSS backdrop-filter over the desk wallpaper), so the wallpaper
# shows through wherever the picture sits. Never uses anyone's real usage: the usage widget reads transcripts written
# by scripts/make_demo.py, the leaderboard pictures use made-up names.
# German needs the renderers inside an .app with de.lproj, taken from the installed TokenMaccer.app.
# Usage: scripts/render_site_images.sh [path to TokenMaccer.app]   (default /Applications/TokenMaccer.app)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/Applications/TokenMaccer.app}"
WIDGET_RES="$APP/Contents/PlugIns/TokenMaccerWidget.appex/Contents/Resources"
APP_RES="$APP/Contents/Resources"
for r in "$WIDGET_RES" "$APP_RES"; do
    [ -d "$r/de.lproj" ] && [ -f "$r/Assets.car" ] || { echo "no de.lproj or Assets.car in $r"; exit 1; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tm-site.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT=docs/assets

# bundle <name> <resources dir>: an .app shell so Bundle.main finds the German strings and the asset-catalog colours
# (Palette: TrendUp and others; without Assets.car they render clear)
bundle() {
    mkdir -p "$WORK/$1.app/Contents/MacOS" "$WORK/$1.app/Contents/Resources"
    cp -R "$2/de.lproj" "$2/Assets.car" "$WORK/$1.app/Contents/Resources/"
    mkdir -p "$WORK/$1.app/Contents/Resources/en.lproj"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.tm-%s</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>\n' "$1" \
        > "$WORK/$1.app/Contents/Info.plist"
    echo "$WORK/$1.app/Contents/MacOS/$1"
}

USAGE_BIN=$(bundle usage "$WIDGET_RES")
BOARD_BIN=$(bundle board "$WIDGET_RES")
PANEL_BIN=$(bundle panel "$APP_RES")
xcrun swiftc app/Shared/*.swift app/Preview/main.swift -o "$USAGE_BIN"
xcrun swiftc app/Shared/*.swift app/Preview/LeaderboardWidget/main.swift -o "$BOARD_BIN"
xcrun swiftc -parse-as-library app/Shared/*.swift app/App/LeaderboardViews.swift app/App/GroupViews.swift \
    app/Preview/Leaderboard/main.swift -o "$PANEL_BIN"

python3 -I scripts/make_demo.py "$WORK/demo-claude" > /dev/null
TOKENMACCER_CLAUDE_DIR="$WORK/demo-claude" TOKENMACCER_DATA_DIR="$WORK/demo-data" python3 -I collector/collector.py > /dev/null

export TM_RENDER_CLEAR=1
for lang in en de; do
    if [ "$lang" = de ]; then L=(-AppleLanguages '(de)' -AppleLocale de_DE); else L=(-AppleLanguages '(en)' -AppleLocale en_US); fi
    mkdir -p "$WORK/$lang"
    "$USAGE_BIN" "$WORK/demo-data/widget.json" "$WORK/$lang" 7D "${L[@]}" > /dev/null
    "$BOARD_BIN" "$WORK/$lang" "${L[@]}" > /dev/null
    "$PANEL_BIN" "$WORK/$lang" "${L[@]}" > /dev/null
    cp "$WORK/$lang/7D_large_dark.png" "$OUT/widget-dark-$lang.png"
    cp "$WORK/$lang/board_globalgroups_medium_dark.png" "$OUT/board-widget-dark-$lang.png"
    cp "$WORK/$lang/board_group_medium_dark.png" "$OUT/group-widget-dark-$lang.png"
    PANEL=("$WORK/$lang"/menubar-joined-dark-*.png)   # one file; its suffix is the bundle's language code
    cp "${PANEL[0]}" "$OUT/menubar-dark-$lang.png"
done
for f in widget board-widget group-widget menubar; do
    for lang in en de; do
        printf '%s ' "$OUT/$f-dark-$lang.png"; sips -g pixelWidth -g pixelHeight "$OUT/$f-dark-$lang.png" | awk 'NR>1{printf "%s ", $2}'; echo
    done
done
