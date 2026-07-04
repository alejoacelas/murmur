#!/usr/bin/env bash
# make-cert.sh — create a STABLE self-signed code-signing identity for Murmur.
#
# Why: ad-hoc signatures (`codesign --sign -`) change their designated requirement
# on every build, so macOS TCC (Microphone / Input Monitoring / Accessibility) grants
# are lost on each rebuild. A stable cert keeps the designated requirement constant,
# so a one-time permission grant survives all rebuilds within the dev machine.
#
# This is fully non-interactive: we create a DEDICATED keychain whose password we own,
# so `security set-key-partition-list` can pre-authorize codesign without any GUI prompt.
#
# Idempotent: re-running is a no-op once the identity exists.
set -euo pipefail

IDENTITY="${MURMUR_CODESIGN_IDENTITY:-Murmur Dev}"
KC_PASS="${MURMUR_KC_PASS:-murmur-dev}"
KC="$HOME/Library/Keychains/murmur-dev.keychain-db"

# Note: a self-signed cert lists WITHOUT -v (it's "not trusted" for the policy) but
# codesign can still use it, so check the full identity list, not just valid ones.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "make-cert: identity '$IDENTITY' already present — nothing to do."
  # Make sure the keychain is in the search list and unlocked so signing works.
  if [ -f "$KC" ]; then
    security unlock-keychain -p "$KC_PASS" "$KC" 2>/dev/null || true
  fi
  exit 0
fi

echo "make-cert: creating self-signed code-signing identity '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Self-signed cert + key with the Code Signing EKU.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY/O=Murmur/C=US" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# 2) Bundle into a PKCS#12 for import.
openssl pkcs12 -export -out "$TMP/murmur.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENTITY" -passout pass:"$KC_PASS" >/dev/null 2>&1

# 3) Dedicated keychain we control (so no login-keychain password prompt).
if [ ! -f "$KC" ]; then
  security create-keychain -p "$KC_PASS" "$KC"
fi
security set-keychain-settings "$KC"              # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC"

# Add to the user search list (keep the existing keychains too).
EXISTING="$(security list-keychains -d user | sed -e 's/[[:space:]]*"//' -e 's/"$//')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $EXISTING >/dev/null

# 4) Import the identity, allowing codesign + security to use the key.
security import "$TMP/murmur.p12" -k "$KC" -P "$KC_PASS" \
  -A -T /usr/bin/codesign -T /usr/bin/security

# 5) Pre-authorize codesign so it never shows a keychain prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

echo "make-cert: done."
security find-identity -v -p codesigning | grep "$IDENTITY" || true
