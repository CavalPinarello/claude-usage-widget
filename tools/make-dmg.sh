#!/bin/bash
# Builds dist/Headroom-<version>.dmg: a universal Headroom.app next to an
# Applications shortcut. The installed copy in ~/Applications is not touched.
#
#   tools/make-dmg.sh            (from the repo root)
#
# The app is ad-hoc signed, not notarized: on first open macOS asks the person
# to allow it under System Settings > Privacy & Security (see README).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d)/Headroom"
mkdir -p "$STAGE" "$ROOT/dist"

HEADROOM_APP="$STAGE/Headroom.app" HEADROOM_NO_LAUNCH=1 HEADROOM_UNIVERSAL=1 "$ROOT/build.sh"
ln -s /Applications "$STAGE/Applications"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Headroom.app/Contents/Info.plist")"
OUT="$ROOT/dist/Headroom-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Headroom" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
