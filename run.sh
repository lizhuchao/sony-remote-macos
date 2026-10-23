#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/build/Sony BRAVIA Remote.app"

if [[ ! -x "$APP_DIR/Contents/MacOS/SonyRemote" ]]; then
  "$PROJECT_DIR/build.sh"
fi

open "$APP_DIR"
