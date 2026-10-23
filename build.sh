#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/build/Sony Remote.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR"
swiftc \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -o "$MACOS_DIR/SonyRemote" \
  "$PROJECT_DIR/SonyRemote.swift"

cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
