#!/usr/bin/env bash
# The one check chain before every build. release.sh and CI run it; any failure stops the build.
#
#   scripts/preflight.sh                 everything (what release.sh runs)
#   scripts/preflight.sh python shell    only these sections; CI splits them over two jobs
#
# Sections:
#   python  ruff check + format, mypy strict (pinned, in the repo venv .venv, never the system Python),
#           unit tests on the macOS system Python the collector runs on
#   shell   bash -n and shellcheck on every shell script
#   deno    deno check and deno lint on the Supabase edge functions
#   swift   both app editions with warnings as errors, XCTest, Swift/Python collector parity, German for
#           every string, Sparkle signature checker, release endpoint lock, preview render, build copies
#           unregistered from Launch Services (scripts/unregister_build_apps.sh)
#
# Tools: xcodegen, shellcheck, deno (brew install xcodegen shellcheck deno). The venv is created on first
# run (needs the network once); TM_VENV points elsewhere if wanted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUFF_VERSION=0.17.0
MYPY_VERSION=1.19.1
VENV="${TM_VENV:-$ROOT/.venv}"
SYSTEM_PYTHON=/usr/bin/python3

step() { printf '\n==> preflight: %s\n' "$*"; }
die() { echo "preflight FAILED: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 missing: brew install $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tokenmaccer-preflight.XXXXXX")"
trap 'rm -rf "$TMP"; "$ROOT/scripts/unregister_build_apps.sh" >/dev/null 2>&1 || true' EXIT

ensure_venv() {
  if [ "$("$VENV/bin/ruff" --version 2>/dev/null)" != "ruff $RUFF_VERSION" ] \
    || ! "$VENV/bin/mypy" --version 2>/dev/null | grep -q "^mypy $MYPY_VERSION "; then
    step "venv $VENV (ruff $RUFF_VERSION, mypy $MYPY_VERSION)"
    "$SYSTEM_PYTHON" -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --disable-pip-version-check "ruff==$RUFF_VERSION" "mypy==$MYPY_VERSION"
  fi
}

python_checks() {
  ensure_venv
  step "ruff"
  "$VENV/bin/ruff" check .
  "$VENV/bin/ruff" format --check .
  step "mypy strict"
  "$VENV/bin/mypy" collector tests scripts supabase/tests
  step "unit tests (macOS system Python)"
  "$SYSTEM_PYTHON" -m unittest discover -s tests
}

shell_checks() {
  need shellcheck
  local scripts=(install.sh uninstall.sh scripts/*.sh)
  step "bash -n + shellcheck (${#scripts[@]} scripts)"
  for s in "${scripts[@]}"; do bash -n "$s"; done
  shellcheck "${scripts[@]}"
}

deno_checks() {
  need deno
  local fns=(supabase/functions/*/index.ts)
  step "deno check + lint (${#fns[@]} edge functions)"
  NO_COLOR=1 deno check "${fns[@]}"
  NO_COLOR=1 deno lint "${fns[@]}"
}

swift_checks() {
  need xcodegen
  # xcode-select may point at the Command Line Tools; fall back to Xcode as release.sh does
  if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  xcodebuild -version >/dev/null 2>&1 || die "xcodebuild needs Xcode (set DEVELOPER_DIR or xcode-select -s)"
  cd "$ROOT/app"
  step "xcodegen"
  xcodegen generate --quiet
  step "build, open-source edition (unsigned, warnings as errors)"
  xcodebuild -project TokenMaccer.xcodeproj -scheme TokenMaccer -configuration Release \
    -derivedDataPath build.noindex CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=CI00000000 build -quiet
  step "XCTest (Swift collector)"
  xcodebuild -project TokenMaccer.xcodeproj -scheme tokenmaccer-collector \
    -derivedDataPath build.noindex CODE_SIGNING_ALLOWED=NO test -quiet
  step "build, app edition (unsigned, universal, warnings as errors)"
  xcodebuild -project TokenMaccer.xcodeproj -scheme TokenMaccer -configuration Release \
    -derivedDataPath build-appedition.noindex -xcconfig AppEdition.xcconfig \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=YES clean build -quiet
  local app=build-appedition.noindex/Build/Products/Release/TokenMaccer.app/Contents
  for bin in "$app/MacOS/TokenMaccer" "$app/MacOS/tokenmaccer-collector" \
             "$app/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"; do
    lipo "$bin" -verify_arch arm64 x86_64
  done
  plutil -lint "$app/Library/LaunchAgents/io.github.valentinherrera.tokenmaccer.collector.plist" >/dev/null
  cd "$ROOT"

  step "Swift and Python collector agree on demo data"
  "$SYSTEM_PYTHON" scripts/make_demo.py "$TMP/parity"
  "$SYSTEM_PYTHON" -I scripts/compare_collectors.py --claude-dir "$TMP/parity" \
    --swift app/build.noindex/Build/Products/Debug/tokenmaccer-collector
  step "every string the build found has German in the String Catalog"
  "$SYSTEM_PYTHON" -I scripts/check_strings.py --derived app/build-appedition.noindex
  step "Sparkle signature check of release.sh type-checks"
  xcrun swiftc -typecheck scripts/verify_ed_signature.swift
  step "release build ignores leaderboard server overrides (Debug honours them)"
  scripts/check_release_endpoint.sh \
    app/build-appedition.noindex/Build/Products/Release/TokenMaccer.app/Contents/MacOS/tokenmaccer-collector \
    app/build.noindex/Build/Products/Debug/tokenmaccer-collector
  step "preview render with demo data"
  "$SYSTEM_PYTHON" scripts/make_demo.py "$TMP/claude"
  TOKENMACCER_CLAUDE_DIR="$TMP/claude" TOKENMACCER_DATA_DIR="$TMP/data" \
    "$SYSTEM_PYTHON" -I collector/collector.py
  xcrun swiftc app/Shared/*.swift app/Preview/main.swift -o "$TMP/render"
  mkdir -p "$TMP/png"
  "$TMP/render" "$TMP/data/widget.json" "$TMP/png" 7D 30D -AppleLocale en_US >/dev/null
  local n
  n="$(find "$TMP/png" -name '*.png' | wc -l | tr -d ' ')"
  [ "$n" -eq 12 ] || die "preview render wrote $n images, expected 12"
  step "build copies of TokenMaccer.app unregistered (widget gallery shows only the installed app)"
  scripts/unregister_build_apps.sh
  scripts/unregister_build_apps.sh --check || die "a build copy is still registered with Launch Services"
}

sections=("$@")
[ ${#sections[@]} -gt 0 ] || sections=(python shell deno swift)
for s in "${sections[@]}"; do
  case "$s" in
    python) python_checks ;;
    shell) shell_checks ;;
    deno) deno_checks ;;
    swift) swift_checks ;;
    *) die "unknown section '$s' (python, shell, deno, swift)" ;;
  esac
done
step "all green (${sections[*]})"
