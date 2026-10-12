#!/bin/bash
# Build Fanyi.app (release) and ad-hoc sign it.
# Optional: SIGN_ID="My Local Codesign Cert" ./build.sh  to sign with a stable
# local identity instead of ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Fanyi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Fanyi" "$APP/Contents/MacOS/Fanyi"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>Fanyi</string>
    <key>CFBundleIdentifier</key>
    <string>ai.mars.fanyi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Fanyi</string>
    <key>CFBundleDisplayName</key>
    <string>Fanyi</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Fanyi 需要读取当前应用中选中的文字，以便翻译或改写。</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep -s "${SIGN_ID:--}" --identifier ai.mars.fanyi "$APP"

echo "Built: $(pwd)/$APP"
