#!/bin/bash
# Build Markdown Reader.app — a self-contained native macOS Markdown viewer.
#
#   ./build.sh              build for this Mac
#   ./build.sh --universal  build a universal (arm64 + x86_64) binary, for releases
set -euo pipefail

UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Markdown Reader.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

if (( UNIVERSAL )); then
    echo "==> Compiling Swift (universal: arm64 + x86_64)"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    for ARCH in arm64 x86_64; do
        swiftc -O \
            -target "$ARCH-apple-macos11.0" \
            -framework Cocoa -framework WebKit \
            -o "$TMP/MarkdownReader-$ARCH" \
            "$ROOT/Sources/main.swift"
    done
    lipo -create "$TMP/MarkdownReader-arm64" "$TMP/MarkdownReader-x86_64" \
        -output "$MACOS/MarkdownReader"
else
    echo "==> Compiling Swift"
    swiftc -O \
        -framework Cocoa -framework WebKit \
        -o "$MACOS/MarkdownReader" \
        "$ROOT/Sources/main.swift"
fi

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
