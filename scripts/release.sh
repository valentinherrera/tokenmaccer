#!/bin/bash
# Builds the downloadable app edition, notarizes it and wraps it in a notarized DMG.
#
#   scripts/release.sh [VERSION]      VERSION defaults to MARKETING_VERSION in app/project.yml
#
# Output in dist/: TokenMaccer-VERSION.dmg (signed, notarized, stapled), the Sparkle update archive
# TokenMaccer-VERSION-BUILD.zip (the notarized, stapled app), appcast.xml (EdDSA-signed entry for that archive)
# and notarization-VERSION.txt. Upload the DMG, the zip and appcast.xml to the GitHub release vVERSION.
# Needs Xcode, xcodegen, a "Developer ID Application" certificate in the keychain and a notarytool
# keychain profile (xcrun notarytool store-credentials). Override for your own account:
#   TM_SIGN_IDENTITY   default "Developer ID Application: Valentin Melchior Herrera-Schäfer (3KM85F22L8)"
#   TM_TEAM            default 3KM85F22L8
#   TM_BUNDLE_ID_PREFIX default io.github.valentinherrera
#   TM_NOTARY_PROFILE  default tokenmaccer-notary
#   TM_NOTARIZE=0      local test build: signed but not notarized, written to dist/test/ (never upload these)
#   TM_DOWNLOAD_URL_PREFIX  where the update archive will be downloaded from, default
#                      https://github.com/valentinherrera/tokenmaccer/releases/download/vVERSION/
# Sparkle's EdDSA private key must be in the login keychain (Sparkle's generate_keys, run once per maintainer);
# its public key is TM_SPARKLE_PUBLIC_KEY in app/project.yml. generate_appcast signs with the keychain key;
# on its first run macOS asks to let generate_appcast use that key (Always Allow), so run it unlocked.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${TM_SIGN_IDENTITY:-Developer ID Application: Valentin Melchior Herrera-Schäfer (3KM85F22L8)}"
TEAM="${TM_TEAM:-3KM85F22L8}"
PREFIX="${TM_BUNDLE_ID_PREFIX:-io.github.valentinherrera}"
PROFILE="${TM_NOTARY_PROFILE:-tokenmaccer-notary}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

VERSION="${1:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/app/project.yml" | head -1)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "invalid version: '$VERSION'" >&2; exit 2; }

BUILD="$ROOT/app/build-release"   # derived data, archive, export: always from scratch
NOTARIZE="${TM_NOTARIZE:-1}"
DIST="$ROOT/dist"
[ "$NOTARIZE" = 1 ] || DIST="$ROOT/dist/test"
APP_NAME="TokenMaccer.app"
DMG="$DIST/TokenMaccer-$VERSION.dmg"
NOTES="$DIST/notarization-$VERSION.txt"
URL_PREFIX="${TM_DOWNLOAD_URL_PREFIX:-https://github.com/valentinherrera/tokenmaccer/releases/download/v$VERSION/}"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"
# The DMG must match a commit: refuse a dirty tree unless TM_ALLOW_DIRTY=1.
if [ "${TM_ALLOW_DIRTY:-0}" != 1 ] && [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
  die "uncommitted changes; commit first (or TM_ALLOW_DIRTY=1 for a test build)"
fi
# The app talks to the hosted project in supabase/app-config.json. A public build must not ship before that
# project has the schema and the functions (join, report and leave would fail for every user): set
# "remote_schema_deployed" to true only after `supabase db push` and the function deploys went through.
if [ "$NOTARIZE" = 1 ]; then
  [ "$(plutil -extract remote_schema_deployed raw "$ROOT/supabase/app-config.json" 2>/dev/null)" = true ] \
    || die "supabase/app-config.json: remote_schema_deployed is not true; deploy the leaderboard schema and functions first (TM_NOTARIZE=0 for a local test build)"
fi
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at $DEVELOPER_DIR"
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || die "signing identity not in keychain: $IDENTITY"

# Submit a file, wait, print the id. On anything but "Accepted" print Apple's log and stop.
notarize() {
  local file="$1" label="$2" out id status
  out="$BUILD/notary-$label.plist"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format plist >"$out" \
    || true
  id="$(plutil -extract id raw "$out" 2>/dev/null || echo "?")"
  status="$(plutil -extract status raw "$out" 2>/dev/null || echo "submit failed")"
  echo "$label: id $id, status $status" | tee -a "$NOTES"
  if [ "$status" != "Accepted" ]; then
    [ "$id" != "?" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    die "notarization of $label: $status"
  fi
}

# Developer ID, hardened runtime, secure timestamp, our team, expected identifier, both architectures.
check_macho() {
  local bin="$1" ident="$2" info
  info="$(codesign -dvvv "$bin" 2>&1)"
  grep -qx "Identifier=$ident" <<<"$info" || die "$bin: identifier is not $ident"
  grep -qx "TeamIdentifier=$TEAM" <<<"$info" || die "$bin: team is not $TEAM"
  grep -q "^Authority=Developer ID Application" <<<"$info" || die "$bin: not signed with Developer ID"
  grep -q "^Timestamp=" <<<"$info" || die "$bin: no secure timestamp"
  grep -q "flags=.*(runtime)" <<<"$info" || die "$bin: no hardened runtime"
  if codesign -d --entitlements - --xml "$bin" 2>/dev/null | grep -q "get-task-allow"; then
    die "$bin: has get-task-allow (notarization rejects it)"
  fi
  lipo "$bin" -verify_arch arm64 x86_64 || die "$bin: not universal"
  printf '  ok  %-34s %s\n' "$ident" "$(lipo -archs "$bin")"
}

step "TokenMaccer $VERSION, team $TEAM, notary profile $PROFILE"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"
rm -f "$DMG" "$NOTES"
echo "commit $COMMIT$([ "${TM_ALLOW_DIRTY:-0}" = 1 ] && echo " (dirty allowed)")" > "$NOTES"

step "Archive (clean, app edition, universal)"
cd "$ROOT/app"
xcodegen generate --quiet
# Sparkle comes from SwiftPM; netrc instead of the keychain: a public download must never wait for a keychain prompt
xcodebuild -project TokenMaccer.xcodeproj -scheme TokenMaccer -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD/derived" -archivePath "$BUILD/TokenMaccer.xcarchive" \
  -xcconfig AppEdition.xcconfig \
  DEVELOPMENT_TEAM="$TEAM" BUNDLE_ID_PREFIX="$PREFIX" CODE_SIGN_IDENTITY="$IDENTITY" \
  MARKETING_VERSION="$VERSION" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  -packageAuthorizationProvider netrc \
  archive -quiet

step "Export (Developer ID)"
cp "$ROOT/scripts/ExportOptions.plist" "$BUILD/ExportOptions.plist"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM" "$BUILD/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$BUILD/TokenMaccer.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" -exportPath "$BUILD/export" -quiet
APP="$BUILD/export/$APP_NAME"
[ -d "$APP" ] || die "export produced no $APP_NAME"

step "Verify signatures and architectures"
codesign --verify --deep --strict --verbose=1 "$APP"
check_macho "$APP/Contents/MacOS/TokenMaccer" "$PREFIX.tokenmaccer"
check_macho "$APP/Contents/MacOS/tokenmaccer-collector" "$PREFIX.tokenmaccer.collector"
check_macho "$APP/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget" \
  "$PREFIX.tokenmaccer.widget"
plutil -lint "$APP/Contents/Library/LaunchAgents/$PREFIX.tokenmaccer.collector.plist" >/dev/null
# Sparkle: framework, helpers and XPC services carry our signature with hardened runtime and timestamp
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
check_macho "$SPK/Sparkle" org.sparkle-project.Sparkle
check_macho "$SPK/Autoupdate" org.sparkle-project.Sparkle.Autoupdate
check_macho "$SPK/Updater.app/Contents/MacOS/Updater" org.sparkle-project.Sparkle.Updater
check_macho "$SPK/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" org.sparkle-project.DownloaderService
check_macho "$SPK/XPCServices/Installer.xpc/Contents/MacOS/Installer" org.sparkle-project.InstallerLauncher
for plist in "$APP/Contents/Info.plist" "$APP/Contents/PlugIns/TokenMaccerWidget.appex/Contents/Info.plist"; do
  got="$(plutil -extract CFBundleShortVersionString raw "$plist")"
  [ "$got" = "$VERSION" ] || die "$plist: version $got, expected $VERSION"
done
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
FEED="$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")"
EDKEY="$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")"
[[ "$FEED" == https://* ]] || die "SUFeedURL is not https: $FEED"
[[ "$EDKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "SUPublicEDKey missing or malformed"
echo "  ok  build $BUILD_NUMBER, feed $FEED"
# Sparkle offers an update only for a higher build, and the self-heal records the build: never release a
# build number twice. Compare with the last local appcast and the live feed (404 before the first release).
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "CFBundleVersion is not a plain number: $BUILD_NUMBER"
PREVIOUS=0
for feed_xml in "$(cat "$DIST/appcast.xml" 2>/dev/null)" "$(curl -fsSL --max-time 20 "$FEED" 2>/dev/null)"; do
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" -gt "$PREVIOUS" ] && PREVIOUS="$n"
  done < <(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' <<<"$feed_xml" | grep -oE '[0-9]+')
done
[ "$BUILD_NUMBER" -gt "$PREVIOUS" ] \
  || die "build $BUILD_NUMBER is not higher than the released build $PREVIOUS; raise CURRENT_PROJECT_VERSION in app/project.yml"
echo "  ok  build $BUILD_NUMBER > last released build $PREVIOUS"

step "Notarize the app"
ditto -c -k --keepParent "$APP" "$BUILD/TokenMaccer-app.zip"
if [ "$NOTARIZE" = 1 ]; then
  notarize "$BUILD/TokenMaccer-app.zip" app
  xcrun stapler staple "$APP"
else
  echo "NOT NOTARIZED (TM_NOTARIZE=0): local test build only" | tee -a "$NOTES"
fi

step "Build the DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname TokenMaccer -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarize the DMG"
if [ "$NOTARIZE" = 1 ]; then
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG"
fi

step "Sparkle update archive and appcast"
SPARKLE_BIN="$BUILD/derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "Sparkle tools not found in $SPARKLE_BIN"
UPDATES="$BUILD/updates"
ZIP="TokenMaccer-$VERSION-$BUILD_NUMBER.zip"
mkdir -p "$UPDATES"
# the app was stapled above, so the update installs offline without a Gatekeeper round trip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATES/$ZIP"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$URL_PREFIX" --maximum-versions 1 \
  -o "$UPDATES/appcast.xml" "$UPDATES"
grep -q "sparkle:edSignature=" "$UPDATES/appcast.xml" || die "appcast entry is not EdDSA-signed"
grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$UPDATES/appcast.xml" \
  || die "appcast does not announce build $BUILD_NUMBER"
grep -qF "url=\"$URL_PREFIX$ZIP\"" "$UPDATES/appcast.xml" || die "appcast does not point at $URL_PREFIX$ZIP"
rm -f "$DIST"/TokenMaccer-"$VERSION"-*.zip
cp "$UPDATES/$ZIP" "$UPDATES/appcast.xml" "$DIST/"
echo "update $ZIP -> $URL_PREFIX$ZIP" | tee -a "$NOTES"

step "Final checks"
if [ "$NOTARIZE" = 1 ]; then
  spctl -a -vvv -t install "$DMG" 2>&1 | tee -a "$NOTES"
  xcrun stapler validate "$DMG"
  xcrun stapler validate "$APP"
  APP_CHECK="$(spctl -a -vv "$APP" 2>&1)"
  echo "$APP_CHECK" | tee -a "$NOTES"
  grep -q "source=Notarized Developer ID" <<<"$APP_CHECK" \
    || die "Gatekeeper does not report the app as Notarized Developer ID"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "sha256 $SHA  $(basename "$DMG")" | tee -a "$NOTES"
echo "sha256 $(shasum -a 256 "$DIST/$ZIP" | cut -d' ' -f1)  $ZIP" | tee -a "$NOTES"
step "Done: $DMG"
