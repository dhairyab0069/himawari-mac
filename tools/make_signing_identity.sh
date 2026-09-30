#!/bin/bash
# Creates "Hanabi Local Code Signing": a self-signed certificate + key in your
# login keychain, used by build.sh to sign every build the same way. macOS keeps
# permissions (Accessibility, Desktop folder, …) per signing identity, so with
# this they survive rebuilds instead of being dropped by every new build.
# It's local only; delete it any time in Keychain Access.
set -euo pipefail
NAME="Hanabi Local Code Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already exists: $NAME"; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:hanabi 2>/dev/null
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P hanabi -T /usr/bin/codesign >/dev/null
echo "Created: $NAME"
