#!/bin/bash
# Builds Scriptorium.app and packs it into build/Scriptorium.dmg for sharing.
# The speech model (Kyutai, ~2.4 GB) and the reading voice (Kokoro, ~0.3 GB) are
# not inside: the app fetches them from Hugging Face on first use.
#
# With a Developer ID certificate the app and the disk image are signed, then
# notarised by Apple and stapled, so it opens on any Mac without warnings. That
# needs a notarytool profile in the keychain, made once with:
#   xcrun notarytool store-credentials scriptorium-notary --apple-id <you> --team-id <team>
# NOTARY_PROFILE names another profile. Without one the image is built but not notarised.
#
#   bash Scripts/make_dmg.sh             # build, sign, notarise
#   bash Scripts/make_dmg.sh --release   # …and publish it as a GitHub release (version from Info.plist)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${NOTARY_PROFILE:-scriptorium-notary}"
DMG=build/Scriptorium.dmg

bash Scripts/build_app.sh
STAGE="$(mktemp -d)"
cp -R build/Scriptorium.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Scriptorium" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

IDENTITY="$(codesign -dvv build/Scriptorium.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "Notarising (a few minutes)…"
        xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature -v "$DMG"
    else
        echo "No notarytool profile '$PROFILE' in the keychain: signed but NOT notarised." >&2
        [ "${1:-}" = "--release" ] && { echo "Refusing to publish an un-notarised release." >&2; exit 1; }
    fi
else
    echo "No Developer ID certificate: ad-hoc signed, NOT notarised." >&2
    [ "${1:-}" = "--release" ] && { echo "Refusing to publish an un-notarised release." >&2; exit 1; }
fi
echo "Built $ROOT/$DMG ($(du -h "$DMG" | cut -f1))"

if [ "${1:-}" = "--release" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    gh release create "v$VERSION" "$DMG" --title "Scriptorium $VERSION" --notes-file Scripts/release_notes.md
fi
