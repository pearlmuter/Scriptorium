#!/bin/bash
# Builds Transcriptaze.app and packs it into build/Transcriptaze.dmg for sharing.
# The speech model (Kyutai, ~2.4 GB) and the reading voice (Kokoro, ~0.3 GB) are
# not inside: the app fetches them from Hugging Face on first use.
#
# The app is ad-hoc signed, not notarised, so on another Mac the first open is:
# right-click the app → Open → Open (or System Settings › Privacy & Security › Open Anyway).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash Scripts/build_app.sh
STAGE="$(mktemp -d)"
cp -R build/Transcriptaze.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/Transcriptaze.dmg
hdiutil create -volname "Transcriptaze" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/Transcriptaze.dmg >/dev/null
rm -rf "$STAGE"
echo "Built $ROOT/build/Transcriptaze.dmg ($(du -h build/Transcriptaze.dmg | cut -f1))"
