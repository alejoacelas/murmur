#!/usr/bin/env bash
# make-fixtures.sh — regenerate the test audio fixtures (§10.3) from macOS `say` TTS so they are
# reproducible and contain no human voice. All output is 16 kHz mono 16-bit PCM WAV.
#
# Also writes Tests/Fixtures/expected.json mapping each file to its expected transcript, so the
# unit tests stay in sync with whatever text was actually spoken.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Tests/Fixtures"
mkdir -p "$DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Optional stable voice; fall back to system default if unavailable.
VOICE="Samantha"
if ! say -v "$VOICE" "" >/dev/null 2>&1; then VOICE=""; fi
say_opts=(); [ -n "$VOICE" ] && say_opts=(-v "$VOICE")

gen() { # gen <outfile> <text>
  local out="$DIR/$1"; shift
  local text="$*"
  say "${say_opts[@]}" "$text" -o "$TMP/x.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/x.aiff" "$out"
  echo "  $1  (\"$text\")"
}

LONG_TEXT="Murmur is a small local dictation tool for macOS. It records your voice, transcribes it entirely on device with Parakeet, and drops the text at your cursor. Nothing is uploaded, there is no account, and there is no cleanup step by default. This clip is about a minute long so the tests exercise chunking and timing over a longer recording without any human speaking into a microphone."

echo "make-fixtures: writing WAVs to $DIR"
gen "hello_world.wav"        "hello world"
gen "the_quick_brown_fox.wav" "the quick brown fox jumps over the lazy dog"
gen "numbers.wav"            "testing one two three"
gen "long_60s.wav"          "$LONG_TEXT"

# silence.wav — 2 seconds of true digital silence (stdlib wave, no deps).
python3 - "$DIR/silence.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b'\x00\x00' * 16000 * 2)
PY
echo "  silence.wav  (2s silence)"

# expected.json — normalized comparison happens in the test; store the plain spoken text.
python3 - "$DIR/expected.json" "$LONG_TEXT" <<'PY'
import json, sys
out, long_text = sys.argv[1], sys.argv[2]
data = {
    "hello_world.wav": "hello world",
    "the_quick_brown_fox.wav": "the quick brown fox jumps over the lazy dog",
    "numbers.wav": "testing one two three",
    "silence.wav": "",
    "long_60s.wav": long_text,
}
with open(out, "w") as f:
    json.dump(data, f, indent=2)
PY
echo "make-fixtures: wrote expected.json"
ls -la "$DIR"
