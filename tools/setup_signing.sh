#!/bin/zsh
# One-time local signing identity. Never reads a Claude credential or asks for its password.
set -eu
SIGNING_NAME='AI Illuminati Local Signing'
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning "$KEYCHAIN" | /usr/bin/awk -v name="$SIGNING_NAME" 'index($0, "\"" name "\"") { found=1 } END { exit !found }'; then
  echo 'Signing identity already exists. No changes needed.'
  exit 0
fi
if security find-certificate -c "$SIGNING_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo 'An existing certificate has no usable signing identity. Repair it in Keychain Access; it will not be replaced automatically.' >&2
  exit 1
fi
SIGNING_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ai-illuminati-signing.XXXXXX")
chmod 700 "$SIGNING_TMP"
trap 'rm -rf "$SIGNING_TMP"' EXIT
cat > "$SIGNING_TMP/cert.conf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = signing
prompt = no
[dn]
CN = AI Illuminati Local Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 \
  -config "$SIGNING_TMP/cert.conf" -keyout "$SIGNING_TMP/key.pem" \
  -out "$SIGNING_TMP/cert.pem" >/dev/null 2>&1
# This fixed transport password is only for the temporary, newly generated package; it is not a user password.
/usr/bin/openssl pkcs12 -export -inkey "$SIGNING_TMP/key.pem" -in "$SIGNING_TMP/cert.pem" \
  -name "$SIGNING_NAME" -out "$SIGNING_TMP/identity.p12" -passout pass:local-import-only
# Only Apple's signing tool is preauthorized for this new key; never allow all applications.
security import "$SIGNING_TMP/identity.p12" -k "$KEYCHAIN" -P 'local-import-only' -x -T /usr/bin/codesign
# User-domain trust limited to code signing. No TLS trust or system trust changes.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$SIGNING_TMP/cert.pem"
security find-identity -v -p codesigning "$KEYCHAIN" | /usr/bin/awk -v name="$SIGNING_NAME" \
  'index($0, "\"" name "\"") { print "Ready: " $2 " " name; found=1 } END { exit !found }'
