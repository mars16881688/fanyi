#!/bin/bash
# Build from the current checkout, copy build/Suiyi.app to ~/Applications, restart it.
set -euo pipefail
cd "$(dirname "$0")"

# Always rebuild: an existing build/Suiyi.app may be from another branch or version.
./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"

# Stop both the current app and the pre-rename Fanyi app, so only one reacts to selections.
pkill -x Suiyi 2>/dev/null || true
pkill -x Fanyi 2>/dev/null || true
sleep 0.5

rm -rf "$DEST/Suiyi.app"
cp -R build/Suiyi.app "$DEST/"
open "$DEST/Suiyi.app"
echo "Installed: $DEST/Suiyi.app"

if [ -d "$DEST/Fanyi.app" ]; then
    echo
    echo "提示：旧版 $DEST/Fanyi.app 仍在。设置、API Key 和 ~/.fanyi 数据会在随译首次启动时自动迁移。"
    echo "确认随译正常后，可手动删除旧版，并在 系统设置 › 通用 › 登录项、隐私与安全性 › 辅助功能 中移除 Fanyi。"
fi
