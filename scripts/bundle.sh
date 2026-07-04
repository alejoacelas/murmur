#!/usr/bin/env bash
# bundle.sh — assemble Murmur.app from a built binary and codesign it with the stable identity.
#
# Usage: bundle.sh <path-to-murmur-binary> [<path-to-murmurctl-binary>]
#
# Produces $APP_PATH (build/Murmur.app). Signs with Hardened Runtime + entitlements using the
# stable "Murmur Dev" cert so TCC grants persist across rebuilds.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

BIN="${1:?usage: bundle.sh <murmur-binary> [murmurctl-binary]}"
CTL_BIN="${2:-}"

if [ ! -f "$BIN" ]; then echo "bundle: binary not found: $BIN" >&2; exit 1; fi

CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# Assemble into a temp bundle, then atomically swap into place so a running app / TCC never
# sees a half-written bundle.
TMP_APP="$(dirname "$APP_PATH")/.$APP_NAME.app.tmp"
rm -rf "$TMP_APP"
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources"

cp "$MURMUR_REPO/assets/Info.plist" "$TMP_APP/Contents/Info.plist"
cp "$BIN" "$TMP_APP/Contents/MacOS/$APP_NAME"
chmod +x "$TMP_APP/Contents/MacOS/$APP_NAME"
# Bundle murmurctl inside so it's available next to the app (handy, not required).
if [ -n "$CTL_BIN" ] && [ -f "$CTL_BIN" ]; then
  cp "$CTL_BIN" "$TMP_APP/Contents/MacOS/murmurctl"
  chmod +x "$TMP_APP/Contents/MacOS/murmurctl"
fi
printf 'APPL????' > "$TMP_APP/Contents/PkgInfo"

# Ensure the signing keychain is available + unlocked.
if [ -f "$MURMUR_KC" ]; then
  security unlock-keychain -p "$MURMUR_KC_PASS" "$MURMUR_KC" 2>/dev/null || true
fi

# Sign inner binaries first (murmurctl), then the app bundle.
if [ -f "$TMP_APP/Contents/MacOS/murmurctl" ]; then
  codesign --force --options runtime --timestamp=none \
    --sign "$CODESIGN_IDENTITY" "$TMP_APP/Contents/MacOS/murmurctl"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements "$MURMUR_REPO/assets/Murmur.entitlements" \
  --sign "$CODESIGN_IDENTITY" "$TMP_APP"

# Atomic-ish swap into the stable path.
mkdir -p "$(dirname "$APP_PATH")"
rm -rf "$APP_PATH"
mv "$TMP_APP" "$APP_PATH"

# Strip any quarantine so it launches without Gatekeeper friction.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "bundle: built + signed $APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Identifier|Authority|Signature|Runtime" | head -6 || true
