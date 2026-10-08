#!/bin/bash
# One-time setup: create a stable self-signed code-signing certificate so
# SnapFlow keeps a constant identity across rebuilds. macOS then remembers the
# Screen Recording grant by (certificate + bundle id) instead of by the binary
# hash, so you only have to authorize once.
#
# Usage:
#   ./setup-signing.sh
#
# You may be prompted (GUI) for your login-keychain password when the cert is
# trusted for code signing — that is expected and happens only once.
set -euo pipefail

cd "$(dirname "$0")"

CERT_NAME="SnapFlow Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Certificate '$CERT_NAME' already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate"
cat > "$TMP/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = SnapFlow Local
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -out "$TMP/cert.p12" -passout pass:snapflow >/dev/null 2>&1

echo "==> Importing into login keychain"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "snapflow" -T /usr/bin/codesign -A

echo "==> Trusting for code signing (may prompt for your keychain password)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> Done. Now run ./build.sh — it will sign with '$CERT_NAME'."
