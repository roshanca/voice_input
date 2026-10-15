#!/bin/bash

# Build a compressed VoiceInput DMG from a signed VoiceInput.app.
#
#   tools/build_dmg.sh <path-to-VoiceInput.app> <output.dmg>
#
# Stages the .app plus an /Applications symlink into a temp dir and packs it
# with hdiutil (UDZO). A custom Finder layout/background can be added later;
# see docs/Release.md.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <VoiceInput.app path> <output.dmg path>" >&2
  exit 64
fi

APP_PATH="$1"
OUTPUT_PATH="$2"
VOLUME_NAME="VoiceInput"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found at $APP_PATH" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP_PATH" "$STAGING_DIR/VoiceInput.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$OUTPUT_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUTPUT_PATH"

hdiutil verify "$OUTPUT_PATH" >/dev/null
echo "Created $OUTPUT_PATH"
