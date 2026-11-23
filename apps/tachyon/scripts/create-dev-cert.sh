#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain.
#
# Signing every build with the same certificate keeps the macOS permissions
# (microphone, accessibility) granted across rebuilds. Run once per machine.
set -euo pipefail

NAME="${CODESIGN_IDENTITY:-Tachyon AI Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "Already exists: $NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# The system openssl (LibreSSL) writes a PKCS#12 that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The PKCS#12 only exists inside $WORK for a moment; its password is a throwaway.
P12_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD"

# -T lets codesign use the key; macOS still asks once, on first use.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

echo "Created: $NAME"
