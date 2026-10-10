#!/bin/zsh
# One-time: creates a self-signed code-signing identity in the login keychain. build.sh then signs with it
# instead of ad-hoc, so the designated requirement ("certificate leaf = H…") is the same for every build and
# TCC grants such as Full Disk Access survive rebuilds. No Apple Developer account; nothing trusts this cert.
# Remove: Keychain Access ▸ login ▸ My Certificates ▸ "DFileManager Local Signing" ▸ Delete.
set -e
NAME="DFileManager Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then echo "“$NAME” already exists"; exit 0; fi
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
cat > $T/cnf <<EOF
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout $T/key.pem -out $T/cert.pem -days 7300 -config $T/cnf 2>/dev/null
P=$(openssl rand -hex 16)
# Keychain only reads the legacy PKCS#12 encryption; LibreSSL writes it by default, OpenSSL 3 needs -legacy.
openssl pkcs12 -export -legacy -inkey $T/key.pem -in $T/cert.pem -out $T/id.p12 -passout pass:$P -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey $T/key.pem -in $T/cert.pem -out $T/id.p12 -passout pass:$P -name "$NAME"
security import $T/id.p12 -k ~/Library/Keychains/login.keychain-db -P $P -T /usr/bin/codesign
echo "Created “$NAME”. Rebuild with ./build.sh and grant Full Disk Access once more — from now on it survives rebuilds."
