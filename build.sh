#!/bin/zsh
# Builds Snag.app in this folder with the Command Line Tools (no Xcode).
# SDK 26.5 on purpose: the 27 SDK turns @State into a macro whose plugin
# only ships with Xcode. The app runs on macOS 27 all the same.
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
APP="Snag.app"
mkdir -p build
xcrun swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos26.0 \
  -module-name Snag Sources/*/*.swift -o build/Snag 2> build/compile.log || {
  grep -E "error:" build/compile.log | sort -u | head -40; echo "Compile failed (build/compile.log)"; exit 1; }
# The helper Claude talks to (MCP over stdio), same engine, no UI.
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos26.0 \
  -module-name SnagMCP Sources/Engine/*.swift Sources/Model/*.swift MCP/main.swift -o build/snag-mcp 2>> build/compile.log || {
  grep -E "error:" build/compile.log | sort -u | head -40; echo "Helper compile failed"; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Snag "$APP/Contents/MacOS/Snag"
cp build/snag-mcp "$APP/Contents/MacOS/snag-mcp"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "Built: $PWD/$APP"
