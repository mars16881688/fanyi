#!/bin/bash
# Kimi build: one-time creation of a stable self-signed code-signing identity on the build Mac.
# Accessibility permission is matched against the app's designated requirement (identifier +
# certificate), so builds signed with this identity keep the permission across updates.
#
# The private key lives in its own keychain (not added to the search list). Its random password is
# kept in a 0600 file in a 0700 folder and only ever reaches `security` on stdin, through the shell
# builtin printf: never in a command line, never printed. Anyone who can run code as this user on
# the build Mac can sign as this identity, so its protection equals the build Mac's.
set -euo pipefail

IDENTITY="Suiyi Kimi Signing"
DIR="$HOME/Library/Application Support/Suiyi Kimi Signing"
PWFILE="$DIR/keychain-password"
KEYCHAIN="$HOME/Library/Keychains/suiyi-kimi-signing.keychain-db"

if [[ -f "$KEYCHAIN" ]]; then
    echo "Signing keychain already exists: $KEYCHAIN"
    security find-identity -p codesigning "$KEYCHAIN"
    exit 0
fi

umask 077
mkdir -p "$DIR"
chmod 700 "$DIR"
/usr/bin/openssl rand -hex 32 > "$PWFILE"
chmod 600 "$PWFILE"

TMP="$(mktemp -d /private/tmp/suiyi-kimi-sign.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<CONFIG
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = $IDENTITY
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -config "$TMP/ext.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
SUIYI_P12="$(/usr/bin/openssl rand -hex 24)"
export SUIYI_P12
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
    -out "$TMP/identity.p12" -passout env:SUIYI_P12
rm -f "$TMP/key.pem"

SEARCH_LIST="$(security list-keychains -d user | tr -d '"' | xargs)"
PW="$(cat "$PWFILE")"
{
    printf 'create-keychain -p %s %s\n' "$PW" "$KEYCHAIN"
    printf 'unlock-keychain -p %s %s\n' "$PW" "$KEYCHAIN"
    printf 'set-keychain-settings %s\n' "$KEYCHAIN"
    printf 'import %s -k %s -P %s -T /usr/bin/codesign\n' "$TMP/identity.p12" "$KEYCHAIN" "$SUIYI_P12"
    printf 'set-key-partition-list -S apple-tool:,apple:,codesign: -s -k %s %s\n' "$PW" "$KEYCHAIN"
} | security -i >/dev/null 2>&1
unset PW SUIYI_P12
# Keep the user's keychain search list as it was; codesign is pointed at this keychain explicitly.
# shellcheck disable=SC2086
security list-keychains -d user -s $SEARCH_LIST

echo "Created signing identity \"$IDENTITY\" in $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN"
