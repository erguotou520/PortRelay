#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/PortRelay.app"

mkdir -p /tmp/portrelay-clang-cache "$DIST_DIR"
CLANG_MODULE_CACHE_PATH=/tmp/portrelay-clang-cache \
    SWIFTPM_ENABLE_SHARED_CACHE=false \
    swift build --disable-sandbox -c release --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR"

BIN_DIR=$(CLANG_MODULE_CACHE_PATH=/tmp/portrelay-clang-cache \
    swift build --disable-sandbox -c release --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --show-bin-path)

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/PortRelay" "$APP_DIR/Contents/MacOS/PortRelay"
cp "$BIN_DIR/PortRelayAskPass" "$APP_DIR/Contents/MacOS/PortRelayAskPass"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod 755 "$APP_DIR/Contents/MacOS/PortRelay" "$APP_DIR/Contents/MacOS/PortRelayAskPass"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
