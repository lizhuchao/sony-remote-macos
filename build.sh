#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/build/Sony BRAVIA Remote.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
swiftc \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework Security \
  -o "$MACOS_DIR/SonyRemote" \
  "$PROJECT_DIR"/*.swift

cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
for locale in en zh-Hans; do
  mkdir -p "$RESOURCES_DIR/$locale.lproj"
  cp "$PROJECT_DIR/Resources/$locale.lproj/Localizable.strings" "$RESOURCES_DIR/$locale.lproj/Localizable.strings"
  cp "$PROJECT_DIR/Resources/$locale.lproj/InfoPlist.strings" "$RESOURCES_DIR/$locale.lproj/InfoPlist.strings"
done
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
