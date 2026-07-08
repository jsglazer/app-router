#!/bin/bash
#
# make-icon.sh — (re)generate Resources/AppIcon.icns from the rendered base glyph.
# Run this only when you want to change the artwork; the .icns is checked in, so a
# normal packaging run (make-dmg.sh) does not need it. Uses only swift + sips +
# iconutil (all built into macOS).
#
set -euo pipefail
cd "$(dirname "$0")/.."

RES_DIR="Resources"
OUT="$RES_DIR/AppIcon.icns"
mkdir -p "$RES_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> rendering base icon"
swift Scripts/makeicon.swift "$TMP/icon_1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> scaling iconset members"
sips -z 16 16   "$TMP/icon_1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$TMP/icon_1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$TMP/icon_1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$TMP/icon_1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$TMP/icon_1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$TMP/icon_1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$TMP/icon_1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$TMP/icon_1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$TMP/icon_1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp              "$TMP/icon_1024.png"        "$ICONSET/icon_512x512@2x.png"

echo "==> iconutil -> $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "wrote $OUT"
