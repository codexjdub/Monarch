#!/bin/bash
set -e

# Kill any running instance before the build so it's fully gone by launch time.
pkill -x Monarch 2>/dev/null || true

echo "Building Monarch..."
swift build -c release

BINARY=".build/release/Monarch"
APP_DIR="Monarch.app/Contents"

rm -rf Monarch.app
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp "$BINARY" "$APP_DIR/MacOS/Monarch"
chmod +x "$APP_DIR/MacOS/Monarch"
cp Resources/Info.plist "$APP_DIR/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Resources/AppIcon.icns"
cp Resources/StatusIcon.png "$APP_DIR/Resources/StatusIcon.png"
cp Resources/AppIconArtwork.png "$APP_DIR/Resources/AppIconArtwork.png"
printf "APPL????" > "$APP_DIR/PkgInfo"

xattr -cr Monarch.app
codesign --deep --force --sign - Monarch.app

echo "Done!"
open Monarch.app
