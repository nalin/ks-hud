#!/bin/sh
# Builds build/KSHud.app from the Swift package, signed with the local identity from setup-signing.sh
# (falls back to ad-hoc signing, which makes macOS re-ask for permissions after every build).
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP=build/KSHud.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KSHud "$APP/Contents/MacOS/KSHud"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGNING="$HOME/Library/Application Support/KSHud/signing"
KEYCHAIN="$SIGNING/signing.keychain-db"
if [ ! -f "$KEYCHAIN" ] || [ ! -f "$SIGNING/password" ]; then
    echo "warning: no local signing identity; run scripts/setup-signing.sh to keep permissions across builds" >&2
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc signed)"
    exit 0
fi

# codesign only finds identities in keychains on the user search list, so add ours just for the
# signing step and always restore the original list (entries may contain spaces).
set --
while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
    [ -n "$entry" ] && set -- "$@" "$entry"
done <<LIST
$(security list-keychains -d user)
LIST
trap 'security list-keychains -d user -s "$@"' EXIT
security unlock-keychain -p "$(cat "$SIGNING/password")" "$KEYCHAIN"
security list-keychains -d user -s "$@" "$KEYCHAIN"
codesign --force --sign "KS HUD Local Signing" "$APP"
echo "Built $APP"
