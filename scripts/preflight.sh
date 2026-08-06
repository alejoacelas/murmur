#!/usr/bin/env bash
# preflight.sh — fail fast unless the environment can actually run the e2e loop (SPEC §10.6):
# active Aqua GUI session, Secure Input off, model cache present. Permission assertions happen
# after app launch via `murmurctl permissions` (they belong to the signed bundle, not this shell).
set -euo pipefail

fail() { echo "preflight: FAIL — $1" >&2; exit 1; }

# 1) Active GUI login session (event taps/posting/windows need one — S13).
launchctl print "gui/$(id -u)" >/dev/null 2>&1 || fail "no active GUI login session for uid $(id -u)"

# 2) Secure Input must be off (blocks synthesized paste — SPEC §8.4).
if ioreg -l -w 0 | grep -q kCGSSessionSecureInputPID; then
  fail "Secure Input is active (a password field or screen lock is holding it)"
fi

# 3) Parakeet model cache present (first-ever download is ~440MB; don't surprise the test loop).
MODEL_DIR="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
if [ -n "${MURMUR_MODEL_CACHE:-}" ]; then MODEL_DIR="$MURMUR_MODEL_CACHE/parakeet-tdt-0.6b-v2"; fi
[ -d "$MODEL_DIR" ] || fail "model cache missing at $MODEL_DIR (run: murmurctl model ensure)"

echo "preflight: OK (GUI session up, Secure Input off, model cached)"
