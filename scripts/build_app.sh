#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="KeynoteSidekick"
PRODUCT_NAME="keynote-sidekick"
APP_EXECUTABLE_NAME="KeynoteSidekick"
APP_DIR="$ROOT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/KeynoteSidekick.png"
ICON_FILE_NAME="AppIcon"
ICON_CANVAS_SIZE=1024
ICON_SCALE="${ICON_SCALE:-0.82}"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swiftpm-module-cache}"

cd "$ROOT_DIR"

swift build --disable-sandbox -c release --product "$PRODUCT_NAME"
BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: expected binary not found at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_EXECUTABLE_NAME"
chmod 755 "$MACOS_DIR/$APP_EXECUTABLE_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  ICON_GENERATED=false

  if command -v magick >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    ICON_TMP_DIR="$(mktemp -d "/tmp/${APP_NAME}-icon.XXXXXX")"
    ICONSET_DIR="$ICON_TMP_DIR/${ICON_FILE_NAME}.iconset"
    ICNS_PATH="$RESOURCES_DIR/${ICON_FILE_NAME}.icns"
    ICON_RENDER_SIZE="$(awk "BEGIN { n = int(${ICON_CANVAS_SIZE} * ${ICON_SCALE}); if (n < 128) n = 128; if (n > ${ICON_CANVAS_SIZE}) n = ${ICON_CANVAS_SIZE}; print n }")"
    mkdir -p "$ICONSET_DIR"

    render_icon() {
      local size="$1"
      local name="$2"
      magick "$ICON_SOURCE" \
        -colorspace sRGB \
        -alpha set \
        -background none \
        -gravity center \
        -resize "${ICON_RENDER_SIZE}x${ICON_RENDER_SIZE}" \
        -extent "${ICON_CANVAS_SIZE}x${ICON_CANVAS_SIZE}" \
        -resize "${size}x${size}" \
        -extent "${size}x${size}" \
        -depth 8 \
        -define png:color-type=6 \
        +profile "*" \
        "PNG32:$ICONSET_DIR/$name"
    }

    render_icon 16 "icon_16x16.png"
    render_icon 32 "icon_16x16@2x.png"
    render_icon 32 "icon_32x32.png"
    render_icon 64 "icon_32x32@2x.png"
    render_icon 128 "icon_128x128.png"
    render_icon 256 "icon_128x128@2x.png"
    render_icon 256 "icon_256x256.png"
    render_icon 512 "icon_256x256@2x.png"
    render_icon 512 "icon_512x512.png"
    render_icon 1024 "icon_512x512@2x.png"

    if iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"; then
      ICON_GENERATED=true
    else
      echo "warning: iconutil failed, falling back to tiff2icns" >&2
    fi
    rm -rf "$ICON_TMP_DIR"
  fi

  if [[ "$ICON_GENERATED" != true ]] && command -v magick >/dev/null 2>&1 && command -v tiff2icns >/dev/null 2>&1; then
    ICON_TMP_DIR="$(mktemp -d "/tmp/${APP_NAME}-icon.XXXXXX")"
    TIFF_PATH="$ICON_TMP_DIR/${ICON_FILE_NAME}.tiff"
    ICNS_PATH="$RESOURCES_DIR/${ICON_FILE_NAME}.icns"
    ICON_RENDER_SIZE="$(awk "BEGIN { n = int(${ICON_CANVAS_SIZE} * ${ICON_SCALE}); if (n < 128) n = 128; if (n > ${ICON_CANVAS_SIZE}) n = ${ICON_CANVAS_SIZE}; print n }")"

    for size in 16 32 64 128 256 512 1024; do
      magick "$ICON_SOURCE" \
        -colorspace sRGB \
        -alpha set \
        -background none \
        -gravity center \
        -resize "${ICON_RENDER_SIZE}x${ICON_RENDER_SIZE}" \
        -extent "${ICON_CANVAS_SIZE}x${ICON_CANVAS_SIZE}" \
        -resize "${size}x${size}" \
        -extent "${size}x${size}" \
        -depth 8 \
        -define png:color-type=6 \
        +profile "*" \
        "PNG32:$ICON_TMP_DIR/icon_${size}.png"
    done

    magick \
      "$ICON_TMP_DIR/icon_16.png" \
      "$ICON_TMP_DIR/icon_32.png" \
      "$ICON_TMP_DIR/icon_64.png" \
      "$ICON_TMP_DIR/icon_128.png" \
      "$ICON_TMP_DIR/icon_256.png" \
      "$ICON_TMP_DIR/icon_512.png" \
      "$ICON_TMP_DIR/icon_1024.png" \
      "$TIFF_PATH"

    tiff2icns "$TIFF_PATH" "$ICNS_PATH"
    ICON_GENERATED=true
    rm -rf "$ICON_TMP_DIR"
  fi

  if [[ "$ICON_GENERATED" != true ]]; then
    echo "warning: icon generation skipped: requires 'magick' plus 'iconutil' or 'tiff2icns'" >&2
  fi
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>KeynoteSidekick</string>
  <key>CFBundleExecutable</key>
  <string>KeynoteSidekick</string>
  <key>CFBundleIdentifier</key>
  <string>com.christian.keynotesidekick</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>KeynoteSidekick</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon</string>
      </array>
    </dict>
  </dict>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Keynote Sidekick needs Apple Events to control Keynote.</string>
</dict>
</plist>
PLIST

echo "Created: $APP_DIR"
