#!/bin/bash
# Kimi build: package with the stable identity from scripts/kimi-signing-setup.sh, so updates keep
# the Accessibility permission. The keychain password reaches `security` on stdin only.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Suiyi Kimi Signing"
KEYCHAIN="$HOME/Library/Keychains/suiyi-kimi-signing.keychain-db"
PWFILE="$HOME/Library/Application Support/Suiyi Kimi Signing/keychain-password"
[[ -f "$KEYCHAIN" && -f "$PWFILE" ]] || { echo "Run scripts/kimi-signing-setup.sh first." >&2; exit 1; }

printf 'unlock-keychain -p %s %s\n' "$(cat "$PWFILE")" "$KEYCHAIN" | security -i >/dev/null 2>&1
SUIYI_SIGN_IDENTITY="$IDENTITY" SUIYI_SIGN_KEYCHAIN="$KEYCHAIN" ./scripts/package.sh

# The designated requirement must name the certificate, not a per-build hash.
codesign -d -r- build/Suiyi.app 2>&1 | grep -q 'certificate leaf' \
    || { echo "Error: not signed with the stable identity." >&2; exit 1; }
