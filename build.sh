#!/bin/bash
# Build Suiyi.app (随译, release) with a stable local identity when available.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Suiyi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Suiyi" "$APP/Contents/MacOS/Suiyi"

# App icon: each size is rendered natively by scripts/make-icon.swift into
# Resources/AppIcon.iconset (run it again after changing the design).
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
        <string>ja</string>
    </array>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>Suiyi</string>
    <key>CFBundleIdentifier</key>
    <string>ai.mars.suiyi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>随译</string>
    <key>CFBundleDisplayName</key>
    <string>随译</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.1</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>随译需要读取当前应用中选中的文字，以便翻译或改写。</string>
</dict>
</plist>
PLIST

# Localized app name and permission prompt (Finder, Dock tooltip, system dialogs).
write_strings() {
    mkdir -p "$APP/Contents/Resources/$1.lproj"
    cat > "$APP/Contents/Resources/$1.lproj/InfoPlist.strings" <<STRINGS
CFBundleName = "$2";
CFBundleDisplayName = "$2";
NSAppleEventsUsageDescription = "$3";
STRINGS
}
write_strings zh-Hans "随译" "随译需要读取当前应用中选中的文字，以便翻译或改写。"
write_strings en "Suiyi" "Suiyi reads the text you select in the current app so it can translate or rewrite it."
write_strings ja "Suiyi" "Suiyi は翻訳や書き換えのため、現在のアプリで選択したテキストを読み取ります。"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
for f in "$APP"/Contents/Resources/*.lproj/InfoPlist.strings; do plutil -lint "$f" >/dev/null; done
SIGN_IDENTITY="${SUIYI_SIGN_IDENTITY:-${SIGN_ID:-Suiyi Local Signing}}"
SIGN_KEYCHAIN="${SUIYI_SIGN_KEYCHAIN:-$HOME/Library/Keychains/suiyi-signing.keychain-db}"
SIGN_PW_SERVICE="suiyi-signing-keychain"
# Reuse the identity created before the rename (scripts/create-signing-cert.sh as Fanyi).
LEGACY_KEYCHAIN="$HOME/Library/Keychains/fanyi-signing.keychain-db"
if [[ -z "${SUIYI_SIGN_IDENTITY:-}${SIGN_ID:-}${SUIYI_SIGN_KEYCHAIN:-}" && ! -f "$SIGN_KEYCHAIN" && -f "$LEGACY_KEYCHAIN" ]]; then
    SIGN_IDENTITY="Fanyi Local Signing"
    SIGN_KEYCHAIN="$LEGACY_KEYCHAIN"
    SIGN_PW_SERVICE="fanyi-signing-keychain"
fi
SIGN_ARGS=(-s -)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    HASH=""
    # 1) Dedicated keychain created by scripts/create-signing-cert.sh (no GUI prompts).
    if [[ -f "$SIGN_KEYCHAIN" ]]; then
        PW="$(security find-generic-password -s "$SIGN_PW_SERVICE" -a "$USER" -w 2>/dev/null || true)"
        [[ -n "$PW" ]] && security unlock-keychain -p "$PW" "$SIGN_KEYCHAIN" 2>/dev/null || true
        HASH="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null \
            | grep -F "\"$SIGN_IDENTITY\"" | head -1 | awk '{print $2}')"
        [[ -n "$HASH" ]] && SIGN_ARGS=(-s "$HASH" --keychain "$SIGN_KEYCHAIN")
    fi
    # 2) Any other keychain in the search list (e.g. a certificate you created yourself).
    if [[ -z "$HASH" ]]; then
        HASH="$(security find-identity -p codesigning 2>/dev/null \
            | grep -F "\"$SIGN_IDENTITY\"" | head -1 | awk '{print $2}')"
        [[ -n "$HASH" ]] && SIGN_ARGS=(-s "$HASH")
    fi
    if [[ -z "$HASH" ]]; then
        echo "警告：未找到代码签名身份 '$SIGN_IDENTITY'，将使用 ad-hoc 签名；重新构建可能需要重新授权辅助功能。" >&2
        echo "请先运行 scripts/create-signing-cert.sh 创建稳定签名身份。" >&2
        SIGN_IDENTITY="-"
    fi
fi
echo "Signing identity: $SIGN_IDENTITY ${HASH:-}"
# Certificate identities get codesign's default designated requirement
# (identifier + certificate leaf hash), which does not change between builds.
# A Developer ID identity (for distribution) also needs the hardened runtime
# and a secure timestamp, both required for notarization.
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign --force --deep "${SIGN_ARGS[@]}" --identifier ai.mars.suiyi "$APP"

echo "Built: $(pwd)/$APP"
