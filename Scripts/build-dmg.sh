#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/PortRelay.app"
ZIP_PATH="$DIST_DIR/PortRelay-macOS.zip"
DMG_PATH="$DIST_DIR/PortRelay.dmg"
STAGING_DIR=$(mktemp -d /tmp/portrelay-dmg.XXXXXX)

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$PROJECT_DIR/Scripts/build-app.sh"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
cp -R "$APP_DIR" "$STAGING_DIR/PortRelay.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
    -volname "PortRelay" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "$ZIP_PATH"
echo "$DMG_PATH"
