#!/bin/zsh
# One-time: creates a self-signed code-signing identity in the login keychain. build.sh then signs with it
# instead of ad-hoc, so the designated requirement ("certificate leaf = H…") is the same for every build and
# TCC grants such as Full Disk Access survive rebuilds. No Apple Developer account; nothing trusts this cert.
# Releases: ./cert.sh "Kermo Release Signing" makes the one package.sh signs with; keep a backup of it (Keychain Access ▸
# Export), since a new one makes every Mac ask for Full Disk Access again once.
# Remove: Keychain Access ▸ login ▸ My Certificates ▸ "DFileManager Local Signing" ▸ Delete.
set -e
NAME=${1:-"DFileManager Local Signing"}
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
# The file name (not -name) is what the keychain shows when codesign first asks for the key: "codesign wants to access key …".
openssl pkcs12 -export -legacy -inkey $T/key.pem -in $T/cert.pem -out "$T/$NAME.p12" -passout pass:$P -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey $T/key.pem -in $T/cert.pem -out "$T/$NAME.p12" -passout pass:$P -name "$NAME"
security import "$T/$NAME.p12" -k ~/Library/Keychains/login.keychain-db -P $P -T /usr/bin/codesign
echo "Created “$NAME”. Rebuild and grant Full Disk Access once more — from now on it survives rebuilds."
