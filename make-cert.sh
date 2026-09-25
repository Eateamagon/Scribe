#!/bin/bash
# Creates the self-signed "Scribe Dev" code signing certificate from the
# command line — the same thing Keychain Access > Certificate Assistant makes,
# for when the GUI route is fiddly.
#
# Everything lands in your login keychain. Nothing is written to this folder.
# macOS will ask you to authorize the trust change; that prompt is expected.

set -euo pipefail

NAME="Scribe Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "'$NAME' already exists. Nothing to do."
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "Creating certificate '$NAME'..."

cat > "$TMP/scribe.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Scribe Dev

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/scribe.key" \
  -out    "$TMP/scribe.crt" \
  -config "$TMP/scribe.cnf" \
  -extensions v3 2>/dev/null

openssl pkcs12 -export \
  -inkey "$TMP/scribe.key" \
  -in    "$TMP/scribe.crt" \
  -name  "$NAME" \
  -out   "$TMP/scribe.p12" \
  -passout pass: 2>/dev/null

echo "Importing into your login keychain..."
security import "$TMP/scribe.p12" -k "$KEYCHAIN" -P "" -A -T /usr/bin/codesign >/dev/null

echo "Marking it trusted for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/scribe.crt"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Done — '$NAME' is ready:"
  security find-identity -v -p codesigning | grep "$NAME"
  echo
  echo "Next:  bash \"$(dirname "$0")/build.sh\""
else
  echo "The certificate was created but codesign does not list it yet."
  echo "Open Keychain Access, find '$NAME' under login > My Certificates,"
  echo "double-click it, expand Trust, and set Code Signing to 'Always Trust'."
  exit 1
fi
