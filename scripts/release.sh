#!/bin/bash
# Builds the downloadable app edition, notarizes it and wraps it in a notarized DMG.
#
#   scripts/release.sh [VERSION]      VERSION defaults to MARKETING_VERSION in app/project.yml
#
# Output in dist/: TokenMaccer-VERSION.dmg (signed, notarized, stapled) and notarization-VERSION.txt.
# Needs Xcode, xcodegen, a "Developer ID Application" certificate in the keychain and a notarytool
# keychain profile (xcrun notarytool store-credentials). Override for your own account:
#   TM_SIGN_IDENTITY   default "Developer ID Application: Valentin Melchior Herrera-Schäfer (3KM85F22L8)"
#   TM_TEAM            default 3KM85F22L8
#   TM_BUNDLE_ID_PREFIX default io.github.valentinherrera
#   TM_NOTARY_PROFILE  default tokenmaccer-notary
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
DIST="$ROOT/dist"
APP_NAME="TokenMaccer.app"
DMG="$DIST/TokenMaccer-$VERSION.dmg"
NOTES="$DIST/notarization-$VERSION.txt"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"
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

step "Archive (clean, app edition, universal)"
cd "$ROOT/app"
xcodegen generate --quiet
xcodebuild -project TokenMaccer.xcodeproj -scheme TokenMaccer -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD/derived" -archivePath "$BUILD/TokenMaccer.xcarchive" \
  -xcconfig AppEdition.xcconfig \
  DEVELOPMENT_TEAM="$TEAM" BUNDLE_ID_PREFIX="$PREFIX" CODE_SIGN_IDENTITY="$IDENTITY" \
  MARKETING_VERSION="$VERSION" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
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
for plist in "$APP/Contents/Info.plist" "$APP/Contents/PlugIns/TokenMaccerWidget.appex/Contents/Info.plist"; do
  got="$(plutil -extract CFBundleShortVersionString raw "$plist")"
  [ "$got" = "$VERSION" ] || die "$plist: version $got, expected $VERSION"
done

step "Notarize the app"
ditto -c -k --keepParent "$APP" "$BUILD/TokenMaccer-app.zip"
notarize "$BUILD/TokenMaccer-app.zip" app
xcrun stapler staple "$APP"

step "Build the DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname TokenMaccer -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarize the DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG"

step "Final checks"
spctl -a -vvv -t install "$DMG" 2>&1 | tee -a "$NOTES"
xcrun stapler validate "$DMG"
xcrun stapler validate "$APP"
APP_CHECK="$(spctl -a -vv "$APP" 2>&1)"
echo "$APP_CHECK" | tee -a "$NOTES"
grep -q "source=Notarized Developer ID" <<<"$APP_CHECK" \
  || die "Gatekeeper does not report the app as Notarized Developer ID"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "sha256 $SHA  $(basename "$DMG")" | tee -a "$NOTES"
step "Done: $DMG"
