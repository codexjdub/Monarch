#!/bin/bash
set -e

echo "Building FolderMenu..."
swift build -c release

BINARY=".build/release/FolderMenu"
APP_DIR="FolderMenu.app/Contents"

rm -rf FolderMenu.app
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp "$BINARY" "$APP_DIR/MacOS/FolderMenu"
chmod +x "$APP_DIR/MacOS/FolderMenu"
cp Resources/Info.plist "$APP_DIR/Info.plist"
printf "APPL????" > "$APP_DIR/PkgInfo"

codesign --deep --force --sign - FolderMenu.app

echo "Done! Run with: open FolderMenu.app"

# Kill any running instance so the next `open` launches the fresh binary
pkill -x FolderMenu 2>/dev/null || true
