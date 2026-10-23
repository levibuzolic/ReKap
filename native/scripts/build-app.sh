#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="${REKAP_APP_PATH:-$TASK_ROOT/build/ReKap.app}"
if [[ -f "$APP_PATH/Contents/MacOS/ReKap" ]] && /usr/sbin/lsof -t "$APP_PATH/Contents/MacOS/ReKap" >/dev/null 2>&1; then
  echo "Quit ReKap before rebuilding this app bundle, or set REKAP_APP_PATH to a different output path." >&2
  exit 1
fi
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rekap-build.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/ReKap.app"
swift build --package-path "$TASK_ROOT" --configuration "$CONFIGURATION" --arch arm64
BIN_DIR="$(swift build --package-path "$TASK_ROOT" --configuration "$CONFIGURATION" --arch arm64 --show-bin-path)"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/ReKap" "$STAGED_APP/Contents/MacOS/ReKap"
cp "$TASK_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$TASK_ROOT/../build/icon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
python3 "$TASK_ROOT/scripts/bundle-encoders.py" "$STAGED_APP"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
mkdir -p "$(dirname "$APP_PATH")"
if [[ -e "$APP_PATH" ]]; then
  mv "$APP_PATH" "$STAGING_ROOT/Previous.app"
fi
mv "$STAGED_APP" "$APP_PATH"
echo "Built $APP_PATH"
