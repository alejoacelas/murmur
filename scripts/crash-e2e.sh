#!/usr/bin/env bash
# crash-e2e.sh — the §10.6 crash-recovery acceptance: SIGKILL the REAL app mid-recording and
# mid-transcription (via fault transcribe-delay-ms), relaunch, and assert each session
# auto-completes from the saved audio. Runs with InsertionProbe focused so recovered pastes are
# contained (recovery inserts into the frontmost app — by design, the user just relaunched).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

FIXTURES="$MURMUR_REPO/Tests/Fixtures"
RUN_DIR="$(mktemp -d /tmp/murmur-crash.XXXXXX)"
export MURMUR_HOME="$RUN_DIR/home"
export MURMUR_SOCK="$RUN_DIR/ctl.sock"
export MURMUR_TRIGGER="ctrl-space"
PROBE_OUT="$RUN_DIR/probe-out.txt"
CTL="$MURMUR_REPO/.build/debug/murmurctl"
PROBE_APP="$MURMUR_REPO/build/InsertionProbe.app"
APP_PID=""

fail() { echo "crash-e2e: FAIL — $1" >&2; exit 1; }

cleanup() {
  "$CTL" quit >/dev/null 2>&1 || true
  pkill -f "InsertionProbe.app/Contents/MacOS/InsertionProbe" 2>/dev/null || true
  [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

launch_app() {
  "$APP_PATH/Contents/MacOS/$APP_NAME" >>"$RUN_DIR/app.log" 2>&1 &
  APP_PID=$!
  "$CTL" wait-ready --timeout 240 >/dev/null || fail "wait-ready (log: $(tail -3 "$RUN_DIR/app.log"))"
}

assert_probe_focused() {
  for _ in $(seq 1 100); do
    if [ -f "$PROBE_OUT.ready" ]; then
      local age; age=$(( $(date +%s) - $(stat -f %m "$PROBE_OUT.ready") ))
      [ "$age" -le 1 ] && return 0
    fi
    sleep 0.2
  done
  fail "InsertionProbe not frontmost — refusing to run recovery pastes"
}

normalize() { tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'; }

clear_probe() {
  touch "$PROBE_OUT.clear"
  for _ in $(seq 1 20); do
    [ ! -f "$PROBE_OUT.clear" ] && [ ! -s "$PROBE_OUT" ] && return 0
    sleep 0.1
  done
  fail "probe did not clear"
}

echo "crash-e2e: run dir $RUN_DIR"
bash "$MURMUR_REPO/scripts/bundle-probe.sh" >/dev/null
open -n "$PROBE_APP" --args --out "$PROBE_OUT"
assert_probe_focused
launch_app

# ---- Case 1: SIGKILL mid-recording ----------------------------------------------------------
( "$CTL" inject "$FIXTURES/long_60s.wav" --realtime >/dev/null 2>&1 & )
REC_ID=""
for _ in $(seq 1 50); do
  REC_ID="$("$CTL" sessions 2>/dev/null | python3 -c '
import json,sys
try:
    ss=json.load(sys.stdin)["sessions"]
    print(next((s["id"] for s in ss if s["state"]=="recording"), ""))
except Exception: print("")')"
  [ -n "$REC_ID" ] && break
  sleep 0.2
done
[ -n "$REC_ID" ] || fail "no session entered recording"
sleep 3  # let a few seconds of audio hit the CAF
kill -9 "$APP_PID"
sleep 0.5
grep -q '"state" : "recording"' "$MURMUR_HOME/recordings/$REC_ID/meta.json" \
  || fail "killed session not left in recording state"
[ -s "$MURMUR_HOME/recordings/$REC_ID/audio.caf" ] || fail "no partial CAF survived"

clear_probe
assert_probe_focused
launch_app  # recovery runs at launch
"$CTL" await-state inserted --id "$REC_ID" --timeout 120 >/dev/null \
  || fail "mid-recording session did not auto-complete (state: $("$CTL" sessions | tail -c 200))"
sleep 0.6
GOT="$(normalize <"$PROBE_OUT")"
case "$GOT" in
  murmur\ is\ a\ small\ local\ dictation\ tool*) : ;;
  *) fail "recovered transcript wrong: \"$GOT\"" ;;
esac
echo "crash-e2e: mid-recording kill -> auto-completed from saved audio OK"

# ---- Case 2: SIGKILL mid-transcription (deterministic via fault delay) -----------------------
"$CTL" fault transcribe-delay-ms 15000 >/dev/null
clear_probe
( "$CTL" inject "$FIXTURES/hello_world.wav" >/dev/null 2>&1 & )
"$CTL" await-state transcribing --timeout 30 >/dev/null || fail "never reached transcribing"
TRANS_ID="$("$CTL" sessions | python3 -c '
import json,sys
ss=json.load(sys.stdin)["sessions"]
print(next(s["id"] for s in ss if s["state"]=="transcribing"))')"
kill -9 "$APP_PID"
sleep 0.5

assert_probe_focused
launch_app  # fault was in-memory; relaunch transcribes for real
"$CTL" await-state inserted --id "$TRANS_ID" --timeout 120 >/dev/null \
  || fail "mid-transcription session did not auto-complete"
sleep 0.6
GOT="$(normalize <"$PROBE_OUT")"
[ "$GOT" = "hello world" ] || fail "mid-transcription recovery transcript: \"$GOT\""
echo "crash-e2e: mid-transcription kill -> auto-completed OK"

echo "crash-e2e: PASS"
