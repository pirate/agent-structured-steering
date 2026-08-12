#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
APP="$ROOT/dist/Structured Steering.app"
CONTENTS="$APP/Contents"
ICON_SOURCE="$ROOT/Assets/AppIcon.png"

swift build -c release --package-path "$ROOT"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/SteeringOverlay" "$CONTENTS/MacOS/Structured Steering"
cp "$ROOT/observer.py" "$ROOT/status-surface.schema.json" "$CONTENTS/Resources/"

iconset="$ROOT/.build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_SOURCE" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$CONTENTS/Resources/AppIcon.icns"

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Structured Steering</string>
  <key>CFBundleExecutable</key><string>Structured Steering</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.sweeting.structured-steering</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Structured Steering</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0.0}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

identity=${CODESIGN_IDENTITY:--}
if [[ "$identity" == "-" ]]; then
  identity=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)"/\1/p' | head -n 1)
  identity=${identity:--}
fi
codesign --force --deep --options runtime --sign "$identity" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Structured-Steering-${VERSION:-1.0.0}.zip"
echo "$APP"
