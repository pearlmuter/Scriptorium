#!/bin/bash
# Builds Transcriptaze.app (release) into ./build/.
#   bash Scripts/build_app.sh            # build
#   bash Scripts/build_app.sh --open     # build and launch
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product Transcriptaze
swift build -c release --product transcriptaze-mcp
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Transcriptaze.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Transcriptaze" "$APP/Contents/MacOS/Transcriptaze"
cp "$BIN/transcriptaze-mcp" "$APP/Contents/MacOS/transcriptaze-mcp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc signature with a stable identifier, so the microphone permission sticks between builds.
codesign --force --sign - --identifier com.transcriptaze.app --entitlements "$ROOT/Resources/Transcriptaze.entitlements" "$APP/Contents/MacOS/transcriptaze-mcp"
codesign --force --sign - --identifier com.transcriptaze.app --entitlements "$ROOT/Resources/Transcriptaze.entitlements" "$APP"
echo "Built $APP"

if [ "${1:-}" = "--open" ]; then open "$APP"; fi
