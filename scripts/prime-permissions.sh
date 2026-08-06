#!/usr/bin/env bash
# prime-permissions.sh — compile the permission primer, bundle+sign it as Murmur.app, launch it,
# and stream its status so the human can grant Microphone / Input Monitoring / Accessibility once.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

bash "$MURMUR_REPO/scripts/make-cert.sh"

BUILD="$MURMUR_REPO/build"
mkdir -p "$BUILD"
BIN="$BUILD/primer-bin"

echo "prime: compiling permission primer…"
swiftc -O -o "$BIN" "$MURMUR_REPO/scripts/permission-primer.swift" \
  -framework AVFoundation -framework CoreGraphics -framework ApplicationServices

# Bundle as Murmur.app (real bundle id + entitlements + stable cert) and run the bundled binary
# directly so TCC associates the grant with the bundle while we capture stdout.
bash "$MURMUR_REPO/scripts/bundle.sh" "$BIN"

echo "prime: launching primer (bundle: $BUNDLE_ID)…"
exec "$APP_PATH/Contents/MacOS/$APP_NAME"
