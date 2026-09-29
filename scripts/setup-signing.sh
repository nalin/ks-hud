#!/bin/sh
# Creates a self-signed code-signing identity in its own keychain (not the login keychain), so macOS
# privacy permissions (Bluetooth, Screen Recording) survive rebuilds. Ad-hoc signatures change on every
# build, which makes macOS treat each build as a new app. Safe to re-run; does nothing if it exists.
set -eu
DIR="$HOME/Library/Application Support/KSHud/signing"
KEYCHAIN="$DIR/signing.keychain-db"
PASSWORD_FILE="$DIR/password"
NAME="KS HUD Local Signing"

umask 077
mkdir -p "$DIR"

if [ -f "$KEYCHAIN" ]; then
    if [ ! -f "$PASSWORD_FILE" ]; then
        # Keychains made by earlier versions of this script used a fixed password; switch to a random one.
        PASSWORD=$(/usr/bin/openssl rand -hex 24)
        security set-keychain-password -o kshud-local -p "$PASSWORD" "$KEYCHAIN"
        printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
        echo "Moved $KEYCHAIN to a random password"
    fi
    echo "Signing identity already set up in $KEYCHAIN"
    exit 0
fi

PASSWORD=$(/usr/bin/openssl rand -hex 24)
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
printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
echo "Created signing identity \"$NAME\" in $KEYCHAIN"
