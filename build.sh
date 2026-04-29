#!/bin/bash
set -e

# Kill any running instance before the build so it's fully gone by launch time.
pkill -x Monarch 2>/dev/null || true

echo "Building Monarch..."
# -Xswiftc -g keeps DWARF debug info in the per-arch binaries so dsymutil
# can extract it into a .dSYM bundle below. Optimizations are unaffected.
swift build -c release --arch arm64 -Xswiftc -g
swift build -c release --arch x86_64 -Xswiftc -g
lipo -create \
    .build/arm64-apple-macosx/release/Monarch \
    .build/x86_64-apple-macosx/release/Monarch \
    -output .build/Monarch-universal

BINARY=".build/Monarch-universal"
APP_DIR="Monarch.app/Contents"

rm -rf Monarch.app
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp -X "$BINARY" "$APP_DIR/MacOS/Monarch"
chmod +x "$APP_DIR/MacOS/Monarch"
cp -X Resources/Info.plist "$APP_DIR/Info.plist"
cp -X Resources/AppIcon.icns "$APP_DIR/Resources/AppIcon.icns"
cp -X Resources/StatusIcon.png "$APP_DIR/Resources/StatusIcon.png"
cp -X Resources/AppIconArtwork.png "$APP_DIR/Resources/AppIconArtwork.png"
printf "APPL????" > "$APP_DIR/PkgInfo"

xattr -cr Monarch.app
codesign --deep --force --sign - Monarch.app

# Extract debug symbols into a sibling .dSYM bundle so future crash reports
# from this build can be symbolicated. Kept locally only (gitignored); the
# shipped .app does not include it.
rm -rf Monarch.app.dSYM
dsymutil "$APP_DIR/MacOS/Monarch" -o Monarch.app.dSYM 2>/dev/null || true

echo "Done!"
open Monarch.app
