#!/bin/bash
# Build Suiyi and package it for colleagues: dist/Suiyi-<version>.zip.
#
# Without a Developer ID the zip uses the local signing identity; recipients
# have to allow it once under System Settings › Privacy & Security.
#
# For a notarized build that opens with no warning:
#   SUIYI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   SUIYI_NOTARY_PROFILE="suiyi-notary" ./scripts/package.sh
# where the profile was saved once with:
#   xcrun notarytool store-credentials suiyi-notary --apple-id <id> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
APP="build/Suiyi.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p dist
ZIP="dist/Suiyi-$VERSION.zip"
STAGE="build/Suiyi-$VERSION"

# The zip holds a folder with the app and the trilingual install guide.
make_zip() {
    rm -rf "$STAGE" "$ZIP"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Suiyi.app"
    cp Resources/Distribution/*.txt "$STAGE/"
    # ditto keeps code signatures and extended attributes intact.
    ditto -c -k --keepParent "$STAGE" "$ZIP"
}
make_zip

if [[ -n "${SUIYI_NOTARY_PROFILE:-}" ]]; then
    if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
        echo "错误：公证需要 Developer ID Application 签名，请设置 SUIYI_SIGN_IDENTITY。" >&2
        exit 1
    fi
    xcrun notarytool submit "$ZIP" --keychain-profile "$SUIYI_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    make_zip
    spctl --assess --type execute --verbose "$APP"
    echo "已公证：$ZIP"
else
    echo "未公证（本机签名）：$ZIP"
    echo "压缩包内附中英日安装说明；同事首次打开需在 系统设置 › 隐私与安全性 中点「仍要打开」。"
fi
shasum -a 256 "$ZIP"
