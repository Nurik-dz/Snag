#!/bin/zsh
# Builds one test against the app's sources and runs it.
#   Tests/run.sh engine <link> <outdir> [video,audio,subs,thumb,desc] [height]   real lookup + download from YouTube
set -e
cd "$(dirname "$0")/.."
NAME="$1"; shift || true
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
case "$NAME" in
  engine) SRC=(Sources/Engine/*.swift Sources/Model/*.swift) ;;
  *) echo "usage: Tests/run.sh engine <link> <outdir> [video,audio,subs,thumb,desc] [height]"; exit 2 ;;
esac
mkdir -p build
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos26.0 \
  "Tests/$NAME/main.swift" $SRC -o "build/test-$NAME"
exec "build/test-$NAME" "$@"
