#!/bin/bash
# Removes the launchd job and the app. Your usage history stays unless you pass --purge.
#
#   ./uninstall.sh            remove job and app, keep ~/.claude/tools/tokenmaccer (history)
#   ./uninstall.sh --purge    also delete ~/.claude/tools/tokenmaccer
set -euo pipefail

LABEL="tokenmaccer.collector"
DATA_DIR="$HOME/.claude/tools/tokenmaccer"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x TokenMaccer 2>/dev/null || true
rm -rf "$HOME/Applications/TokenMaccer.app"
echo "Removed launchd job and app."

if [ "$PURGE" = 1 ]; then
  rm -rf "$DATA_DIR"
  echo "Deleted $DATA_DIR."
else
  echo "Kept your history in $DATA_DIR (delete with --purge)."
fi
