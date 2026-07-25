#!/bin/bash
# Creates a throwaway keychain with two self-signed code-signing identities:
#   SpikeGood  — the identity the listener's requirement pins to
#   SpikeWrong — a valid but different identity, for the rejection test
# Nothing touches the login keychain or the keychain search list; codesign is
# pointed at this keychain explicitly via --keychain.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$DIR/identities"
KEYCHAIN="$WORK/spike.keychain-db"
PASS=spike-throwaway
mkdir -p "$WORK"

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
rm -f "$KEYCHAIN"
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
security unlock-keychain -p "$PASS" "$KEYCHAIN"

make_identity() {
  local name=$1
  cat > "$WORK/$name.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes \
    -keyout "$WORK/$name.key" -out "$WORK/$name.pem" -config "$WORK/$name.cnf" 2>/dev/null
  # -legacy: OpenSSL 3 defaults produce a p12 that `security import` rejects
  # ("MAC verification failed"); the legacy 3DES/RC2 envelope imports cleanly.
  openssl pkcs12 -export -legacy -inkey "$WORK/$name.key" -in "$WORK/$name.pem" \
    -name "$name" -out "$WORK/$name.p12" -passout pass:"$PASS"
  security import "$WORK/$name.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
  openssl x509 -in "$WORK/$name.pem" -outform DER | shasum -a 1 | awk '{print $1}' > "$WORK/$name.sha1"
  echo "$name: cert sha1 $(cat "$WORK/$name.sha1")"
}

make_identity SpikeGood
make_identity SpikeWrong

# Let codesign use the private keys without a UI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

security find-identity -v -p codesigning "$KEYCHAIN"
