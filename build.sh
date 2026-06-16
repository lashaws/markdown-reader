#!/bin/bash
# Build Markdown Reader.app — a self-contained native macOS Markdown viewer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Markdown Reader.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Compiling Swift"
swiftc -O \
    -framework Cocoa -framework WebKit \
    -o "$MACOS/MarkdownReader" \
    "$ROOT/Sources/main.swift"

echo "==> Assembling bundle"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$ROOT/Resources/"* "$RES/"

echo "==> Ad-hoc code signing"
codesign --force --deep -s - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Registering with LaunchServices"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -f "$APP" 2>/dev/null || echo "   (lsregister skipped)"

echo ""
echo "Built: $APP"
echo "Open a file with:  open -a \"$APP\" yourfile.md"
