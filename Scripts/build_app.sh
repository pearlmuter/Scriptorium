#!/bin/bash
# Builds Scriptorium.app (release) into ./build/.
#   bash Scripts/build_app.sh            # build
#   bash Scripts/build_app.sh --open     # build and launch
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product Scriptorium
swift build -c release --product scriptorium-mcp
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Scriptorium.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Scriptorium" "$APP/Contents/MacOS/Scriptorium"
cp "$BIN/scriptorium-mcp" "$APP/Contents/MacOS/scriptorium-mcp"
# Package resource bundles (FluidAudio's), where SwiftPM's Bundle.module finds them.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# The manual, typeset by Scripts/make_manual.swift from Resources/Manual/manual.html.
[ -f "$ROOT/Resources/Manual.pdf" ] && cp "$ROOT/Resources/Manual.pdf" "$APP/Contents/Resources/"

# Signed with the Developer ID when this Mac has one (hardened runtime, timestamped, so it
# can be notarised), else ad-hoc. SIGN_IDENTITY overrides; SIGN_IDENTITY=- forces ad-hoc.
# A stable identifier either way, so the microphone permission sticks between builds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/Scriptorium.entitlements")
[ "$IDENTITY" != "-" ] && SIGN+=(--options runtime --timestamp)
"${SIGN[@]}" --identifier com.scriptorium.mcp "$APP/Contents/MacOS/scriptorium-mcp"
"${SIGN[@]}" --identifier com.scriptorium.app "$APP"
echo "Signed as: $IDENTITY"
echo "Built $APP"

if [ "${1:-}" = "--open" ]; then open "$APP"; fi
