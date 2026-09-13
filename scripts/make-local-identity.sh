#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain, so Beacon keeps a
# *stable* identity across rebuilds.
#
# Why this exists: an ad-hoc signature is keyed by cdhash, which changes on every build. macOS
# ties the keychain ACL ("Always Allow" on Claude Code-credentials) and the Accessibility grant
# to the signing identity, so every rebuild threw both away and the prompts came back. A local
# certificate has no Team ID — notifications still need a real Apple Development identity — but
# it is stable, which is all the keychain and Accessibility care about.
#
# Run once. `scripts/build.sh` picks it up automatically afterwards.
set -euo pipefail

CN="Beacon Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CN" >/dev/null 2>&1; then
    echo "==> '$CN' already exists in the login keychain — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSPHRASE="$(openssl rand -hex 16)"

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$CN
O=Beacon
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
CNF

echo "==> Generating a 10-year self-signed code signing certificate"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null

# The legacy PBE/MAC algorithms are required: OpenSSL 3 defaults produce a PKCS#12 that the
# macOS `security` tool rejects with "MAC verification failed".
openssl pkcs12 -export -out "$WORK/bundle.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$CN" \
    -passout "pass:$PASSPHRASE" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into the login keychain (codesign only)"
# `-T /usr/bin/codesign` and nothing else: only the signing tool may use this key.
security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign

echo "==> Done. It shows as CSSMERR_TP_NOT_TRUSTED, which is expected and fine —"
echo "    codesign signs with it regardless, and the identity is what stays stable."
echo
echo "    Next: scripts/build.sh --install, then answer the keychain prompt with"
echo "    'Always Allow' one last time."
echo
echo "    To remove it later: security delete-certificate -c \"$CN\""
