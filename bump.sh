#!/bin/bash
set -e

PLIST="Resources/Info.plist"

# Read current values.
current_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
current_build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")

# If a version argument was passed, use it; otherwise keep the current version.
if [ -n "$1" ]; then
    new_version="$1"
else
    new_version="$current_version"
fi

# Auto-increment build number.
new_build=$((current_build + 1))

# Write back.
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $new_version" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $new_build" "$PLIST"

echo "Version: $current_version → $new_version"
echo "Build:   $current_build → $new_build"
echo ""

# Hand off to build.sh.
bash build.sh
