#!/usr/bin/env bash
# Unregisters the TokenMaccer.app copies the builds leave in the repo (app/build*, dist/) from Launch Services and
# their widget extensions from PlugInKit, so the widget gallery and "Open With" list only the installed app.
# macOS registers every built bundle it sees; without this each preflight or release run adds another
# "TokenMaccer" to the gallery. Files stay where they are. preflight.sh and release.sh call it on exit.
#
#   scripts/unregister_build_apps.sh          unregister, print how many
#   scripts/unregister_build_apps.sh --check  exit 1 if a build copy is still registered (positive control)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# macOS only; CI runners without Launch Services simply skip it
[ -x "$LSREGISTER" ] || exit 0

apps=()
while IFS= read -r -d '' a; do apps+=("$a"); done < <(
  find "$ROOT/app" "$ROOT/dist" -maxdepth 8 -type d -name '*.app' -path '*TokenMaccer*' -prune -print0 2>/dev/null
)

if [ "${1:-}" = "--check" ]; then
  dump="$("$LSREGISTER" -dump 2>/dev/null)"
  left=0
  for a in "${apps[@]+"${apps[@]}"}"; do
    # "<path> (0x…)" matches the app's own record, not its widget extension's (same prefix + /Contents/PlugIns/…)
    if grep -qF "$a (0x" <<<"$dump"; then
      echo "still registered: $a"; left=$((left + 1))
    fi
  done
  [ "$left" -eq 0 ] && echo "ok  no build copy registered (${#apps[@]} on disk)"
  [ "$left" -eq 0 ]
  exit
fi

for a in "${apps[@]+"${apps[@]}"}"; do
  while IFS= read -r -d '' x; do pluginkit -r "$x" >/dev/null 2>&1 || true; done < <(
    find "$a/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 2>/dev/null
  )
  "$LSREGISTER" -u "$a" >/dev/null 2>&1 || true
done
echo "unregistered ${#apps[@]} build copies of TokenMaccer.app (files kept)"

# The App Intents index keeps pointing at the last registered copy: after the build copies are gone, the installed
# widget's clicks fail ("There is no metadata for NextBoard", measured 02.11.2026 after a preflight run) until the
# installed app is registered again. The app does the same at every launch (StaleCopies); this covers a running app.
installed=/Applications/TokenMaccer.app
if [ "${#apps[@]}" -gt 0 ] && [ -d "$installed" ]; then
  "$LSREGISTER" -f "$installed" >/dev/null 2>&1 && echo "registered $installed again (widget clicks)"
fi
