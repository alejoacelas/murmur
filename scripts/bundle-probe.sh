#!/usr/bin/env bash
# bundle-probe.sh — wrap the InsertionProbe binary as a minimal .app so `open` can launch it
# with real LaunchServices activation (self-activation from a bare binary is ignored when
# another app — e.g. the user's browser — holds focus under macOS 14+ cooperative activation).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

BIN="${1:-$MURMUR_REPO/.build/debug/InsertionProbe}"
PROBE_APP="$MURMUR_REPO/build/InsertionProbe.app"

rm -rf "$PROBE_APP"
mkdir -p "$PROBE_APP/Contents/MacOS"
cat > "$PROBE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>InsertionProbe</string>
    <key>CFBundleIdentifier</key><string>com.alejoacelas.Murmur.probe</string>
    <key>CFBundleExecutable</key><string>InsertionProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
cp "$BIN" "$PROBE_APP/Contents/MacOS/InsertionProbe"
chmod +x "$PROBE_APP/Contents/MacOS/InsertionProbe"
codesign --force --sign - "$PROBE_APP" 2>/dev/null
echo "bundle-probe: $PROBE_APP"
