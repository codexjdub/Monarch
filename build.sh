#!/bin/bash
set -e

# Kill any running instance before the build so it's fully gone by launch time.
pkill -x Monarch 2>/dev/null || true

# ---------------------------------------------------------------------------
# SDK selection
#
# The Command Line Tools' MacOSX27.0.sdk implements SwiftUI's `@State` as a
# macro but ships no SwiftUIMacros plugin (the plugins directory has only
# libObservationMacros and libSwiftMacros). Every `@State` in the project then
# fails to expand, surfacing as a cascade of misleading
# "cannot assign to property: 'self' is immutable" errors in files that have
# not changed.
#
# Probe the active SDK with a one-line SwiftUI file; if it can't build, fall
# back to the newest installed SDK that can. Export SDKROOT yourself to
# override. When Apple ships the missing plugin, the default probe passes and
# the default SDK is used again with no edit needed here.
# ---------------------------------------------------------------------------
probe_sdk() {
    local sdk="$1" dir rc=0
    dir="$(mktemp -d)"
    printf 'import SwiftUI\nstruct P: View { @State private var x = 0\n  var body: some View { Text("\\(x)") } }\n' \
        > "$dir/probe.swift"
    if [ -n "$sdk" ]; then
        swiftc -swift-version 6 -sdk "$sdk" -typecheck "$dir/probe.swift" >/dev/null 2>&1 || rc=1
    else
        swiftc -swift-version 6 -typecheck "$dir/probe.swift" >/dev/null 2>&1 || rc=1
    fi
    rm -rf "$dir"
    return $rc
}

if [ -n "$SDKROOT" ]; then
    echo "SDK: \$SDKROOT from environment — $SDKROOT"
elif probe_sdk ""; then
    : # Default SDK builds SwiftUI fine; nothing to do.
else
    echo "Default SDK cannot expand SwiftUI's @State macro — searching for a usable SDK..."
    for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
        if probe_sdk "$candidate"; then
            export SDKROOT="$candidate"
            echo "SDK: falling back to $SDKROOT"
            break
        fi
    done
    if [ -z "$SDKROOT" ]; then
        echo "error: no installed SDK can compile SwiftUI '@State'." >&2
        echo "       Installing full Xcode provides the SwiftUIMacros plugin." >&2
        exit 1
    fi
fi

# Fail loudly if a build step silently produced nothing — a stale lipo path
# used to abort the script before the bundle was assembled, leaving an old
# Monarch.app in place that looked like a successful build.
verify_slice() {
    local file="$1" want="$2"
    [ -f "$file" ] || { echo "error: expected binary missing: $file" >&2; exit 1; }
    lipo -info "$file" | grep -q "$want" \
        || { echo "error: $file is not $want" >&2; exit 1; }
}

echo "Building Monarch..."
# -Xswiftc -g keeps DWARF debug info in the per-arch binaries so dsymutil
# can extract it into a .dSYM bundle below. Optimizations are unaffected.
#
# Ask SwiftPM where it puts the product rather than hardcoding a layout — the
# path moved between toolchains. Both --arch builds currently emit to the SAME
# directory, so each slice is copied aside before the next build overwrites it.
ARM_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
swift build -c release --arch arm64 -Xswiftc -g
cp -X "$ARM_DIR/Monarch" .build/Monarch-arm64
verify_slice .build/Monarch-arm64 arm64

X86_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"
swift build -c release --arch x86_64 -Xswiftc -g
cp -X "$X86_DIR/Monarch" .build/Monarch-x86_64
verify_slice .build/Monarch-x86_64 x86_64

lipo -create .build/Monarch-arm64 .build/Monarch-x86_64 -output .build/Monarch-universal

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

verify_slice "$APP_DIR/MacOS/Monarch" arm64
verify_slice "$APP_DIR/MacOS/Monarch" x86_64

echo "Done!"
open Monarch.app
