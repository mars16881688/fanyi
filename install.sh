#!/bin/bash
# Copy build/Fanyi.app to ~/Applications, restart it.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d build/Fanyi.app ]; then
    ./build.sh
fi

DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x Fanyi 2>/dev/null || true
sleep 0.5

rm -rf "$DEST/Fanyi.app"
cp -R build/Fanyi.app "$DEST/"
open "$DEST/Fanyi.app"
echo "Installed: $DEST/Fanyi.app"
