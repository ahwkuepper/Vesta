#!/bin/bash
# Create a stable local code-signing identity for Lumo.
#
# Why this exists: build.sh previously signed ad-hoc (`codesign --sign -`). An
# ad-hoc signature has no stable identity — its hash changes with every rebuild —
# so the sandbox gets no stable keychain access group and macOS treats each build
# as a different app asking for the bridge key. That produces a keychain password
# prompt on every single rebuild, and "Always Allow" only ever covers that one
# binary.
#
# A self-signed certificate fixes the cause: the identity stays the same across
# builds, so one "Always Allow" sticks and the key stays encrypted in the Keychain.
set -euo pipefail

NAME="Lumo Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "identity '$NAME' already exists — nothing to do"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT   # the private key lives in the keychain, not on disk

cat > "$WORK/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $NAME
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/req.cnf" 2>/dev/null

# Legacy PKCS#12 algorithms: OpenSSL 3 defaults to PBKDF2 + AES, which macOS's
# SecKeychainItemImport cannot read ("MAC verification failed").
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -name "$NAME" -passout pass:lumo \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

# -T /usr/bin/codesign lets codesign use the key without opening it to every app.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P lumo -T /usr/bin/codesign

# User trust domain only — no admin rights needed, and it affects only this account.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning
