#!/bin/bash
# A Release build of the collector must ignore every leaderboard server override: App Group defaults
# (TMLeaderboardURL/TMLeaderboardKey) and the TOKENMACCER_LEADERBOARD_* environment variables.
# Positive control: a Debug build honours them. Sends no request (`leaderboard endpoint` only prints).
#
#   scripts/check_release_endpoint.sh <Release tokenmaccer-collector> [<Debug tokenmaccer-collector>]
set -euo pipefail

RELEASE="${1:?usage: $0 <Release tokenmaccer-collector> [<Debug tokenmaccer-collector>]}"
DEBUG="${2:-}"
HOSTED="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' \
  "$(dirname "$0")/../supabase/app-config.json")"
FAKE="http://127.0.0.1:59999"
# a throwaway defaults domain, never the real App Group
GROUP="tokenmaccer-endpoint-check-$$"
DATA="$(mktemp -d)"
# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  defaults delete "$GROUP" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$GROUP.plist"
  rm -rf "$DATA"
}
trap cleanup EXIT
defaults write "$GROUP" TMLeaderboardURL "$FAKE"
defaults write "$GROUP" TMLeaderboardKey fake-key

endpoint() {
  local bin="$1"
  shift
  env -i HOME="$HOME" PATH=/usr/bin:/bin "$@" "$bin" leaderboard endpoint --data-dir "$DATA" --app-group "$GROUP"
}

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; fail=1; fi
}
url() { /usr/bin/python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("url", ""), d.get("overrides_allowed"))'; }

check "release: App Group defaults ignored" "$(endpoint "$RELEASE" | url)" "$HOSTED False"
check "release: environment ignored" \
  "$(endpoint "$RELEASE" TOKENMACCER_LEADERBOARD_URL="$FAKE" TOKENMACCER_LEADERBOARD_KEY=k | url)" "$HOSTED False"
if [ -n "$DEBUG" ]; then
  check "debug (positive control): App Group defaults honoured" "$(endpoint "$DEBUG" | url)" "$FAKE True"
fi
exit "$fail"
