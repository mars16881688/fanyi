#!/bin/bash
# Create a per-user, self-signed code-signing identity for local Fanyi builds.
#
# The identity lives in a dedicated keychain (~/Library/Keychains/fanyi-signing.keychain-db)
# whose random password is stored in your login keychain. This lets build.sh sign
# without GUI keychain prompts. Nothing is written into the repository; the
# certificate and key are generated in a temporary directory that is removed on exit.
set -euo pipefail

IDENTITY="${FANYI_SIGN_IDENTITY:-Fanyi Local Signing}"
KEYCHAIN="${FANYI_SIGN_KEYCHAIN:-$HOME/Library/Keychains/fanyi-signing.keychain-db}"
PW_SERVICE="fanyi-signing-keychain"

keychain_password() {
    security find-generic-password -s "$PW_SERVICE" -a "$USER" -w 2>/dev/null || true
}

if [[ -f "$KEYCHAIN" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
    echo "签名身份已存在：${IDENTITY}（${KEYCHAIN}）"
    security find-identity -p codesigning "$KEYCHAIN"
    exit 0
fi

PASSWORD="$(keychain_password)"
if [[ -z "$PASSWORD" ]]; then
    PASSWORD="$(/usr/bin/openssl rand -hex 24)"
    security add-generic-password -s "$PW_SERVICE" -a "$USER" -w "$PASSWORD" \
        -l "Fanyi 本地签名钥匙串密码" -T /usr/bin/security
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

TEMP_DIR="$(mktemp -d /private/tmp/fanyi-signing.XXXXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
umask 077
P12_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
cat > "$TEMP_DIR/extensions.cnf" <<CONFIG
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
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -config "$TEMP_DIR/extensions.cnf" \
    -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem"
LEGACY=()
if [[ "$(/usr/bin/openssl version)" == *"OpenSSL 3"* ]]; then
    LEGACY=(-legacy)
fi
export FANYI_P12_PASSWORD="$P12_PASSWORD"
/usr/bin/openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" -name "$IDENTITY" -out "$TEMP_DIR/identity.p12" \
    -passout env:FANYI_P12_PASSWORD
unset FANYI_P12_PASSWORD
security import "$TEMP_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
# Allow codesign to use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# Optional: mark the certificate as trusted for code signing (shows a password prompt).
# Not required for stable Accessibility permission.
if [[ "${FANYI_TRUST_CERT:-0}" == "1" ]]; then
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TEMP_DIR/cert.pem" \
        || echo "警告：信任设置未完成（可能已取消），不影响签名。" >&2
fi

echo "已创建签名身份：${IDENTITY}（${KEYCHAIN}）"
security find-identity -p codesigning "$KEYCHAIN"
