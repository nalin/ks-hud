#!/bin/sh
# Creates a self-signed code-signing identity in its own keychain (not the login keychain), so macOS
# privacy permissions (Bluetooth, Screen Recording) survive rebuilds. Ad-hoc signatures change on every
# build, which makes macOS treat each build as a new app. Safe to re-run; does nothing if it exists.
set -eu
DIR="$HOME/Library/Application Support/KSHud/signing"
KEYCHAIN="$DIR/signing.keychain-db"
PASSWORD="kshud-local"
NAME="KS HUD Local Signing"

if [ -f "$KEYCHAIN" ]; then
    echo "Signing identity already set up in $KEYCHAIN"
    exit 0
fi

mkdir -p "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASSWORD"

# create-keychain adds the new keychain to the search list; put the list back the way it was
# (entries may contain spaces, so keep them as separate arguments).
set --
while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
    [ -n "$entry" ] && set -- "$@" "$entry"
done <<LIST
$(security list-keychains -d user)
LIST
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$@"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
echo "Created signing identity \"$NAME\" in $KEYCHAIN"
