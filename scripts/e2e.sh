#!/usr/bin/env bash
# e2e.sh — end-to-end via the control socket (SPEC §10.5): launch the SIGNED app bundle by exec,
# wait ready, focus InsertionProbe, inject fixtures, assert the pasted text + clipboard restore.
# Requires: bundle.sh already produced $APP_PATH; permissions granted to the bundle.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

FIXTURES="$MURMUR_REPO/Tests/Fixtures"
RUN_DIR="$(mktemp -d /tmp/murmur-e2e.XXXXXX)"
export MURMUR_HOME="$RUN_DIR/home"
export MURMUR_SOCK="$RUN_DIR/ctl.sock"   # short path: sun_path limit is ~104 bytes
export MURMUR_TRIGGER="ctrl-space"
PROBE_OUT="$RUN_DIR/probe-out.txt"
CTL="$MURMUR_REPO/.build/debug/murmurctl"
PROBE_APP="$MURMUR_REPO/build/InsertionProbe.app"
APP_PID=""

normalize() { # lowercase, strip punctuation, collapse whitespace (SPEC §10.3)
  tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

cleanup() {
  "$CTL" quit >/dev/null 2>&1 || true
  pkill -f "InsertionProbe.app/Contents/MacOS/InsertionProbe" 2>/dev/null || true
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

# The probe's ready marker is a HEARTBEAT: it only exists (with a fresh mtime) while the probe
# window is frontmost + key. Asserting freshness right before pasting keeps a user who grabs
# focus mid-run from receiving stray pastes — the run aborts instead.
assert_probe_focused() {
  for _ in $(seq 1 100); do
    if [ -f "$PROBE_OUT.ready" ]; then
      local age
      age=$(( $(date +%s) - $(stat -f %m "$PROBE_OUT.ready") ))
      [ "$age" -le 1 ] && return 0
    fi
    sleep 0.2
  done
  fail "InsertionProbe is not frontmost (is someone using the machine?) — aborting instead of pasting into the wrong app"
}

fail() { echo "e2e: FAIL — $1" >&2; exit 1; }

echo "e2e: run dir $RUN_DIR"

# 1) Launch the signed bundle by exec (env inherited — S8-independent).
"$APP_PATH/Contents/MacOS/$APP_NAME" >"$RUN_DIR/app.log" 2>&1 &
APP_PID=$!

# 2) Readiness + permission assertions (SPEC §10.5 step 2).
"$CTL" wait-ready --timeout 240 >/dev/null || { tail -5 "$RUN_DIR/app.log" >&2; fail "wait-ready"; }
PERMS_JSON="$("$CTL" permissions)"
for key in microphone inputMonitoring accessibility; do
  echo "$PERMS_JSON" | grep -q "\"$key\":true" || fail "permission not granted: $key ($PERMS_JSON)"
done

# 3) Launch InsertionProbe via `open` (real LaunchServices activation — a bare binary's
#    self-activation is ignored while another app holds focus) and wait until focused.
bash "$MURMUR_REPO/scripts/bundle-probe.sh" >/dev/null
open -n "$PROBE_APP" --args --out "$PROBE_OUT"
assert_probe_focused

# 4) Clipboard sentinel for the restore check (SPEC §10.4 layer 5).
SENTINEL="murmur-sentinel-$$-$RANDOM"
printf '%s' "$SENTINEL" | pbcopy

clear_probe() {
  touch "$PROBE_OUT.clear"
  for _ in $(seq 1 20); do
    [ ! -f "$PROBE_OUT.clear" ] && [ ! -s "$PROBE_OUT" ] && return 0
    sleep 0.1
  done
  fail "probe did not clear"
}

run_case() { # fixture, expected-normalized
  local wav="$1" expected="$2"
  clear_probe
  assert_probe_focused
  local resp
  resp="$("$CTL" inject "$FIXTURES/$wav")" || fail "inject $wav: $resp"
  "$CTL" await-state inserted --timeout 60 >/dev/null || fail "$wav never reached inserted"
  sleep 0.6  # let the paste land + probe mirror + clipboard restore
  local got want
  got="$(normalize <"$PROBE_OUT")"
  want="$(printf '%s' "$expected" | normalize)"
  if [ "$got" != "$want" ]; then
    fail "$wav: probe got \"$got\" want \"$want\""
  fi
  echo "e2e: $wav OK (\"$got\")"
}

run_case hello_world.wav "hello world"

# 5) Silence must insert nothing.
clear_probe
assert_probe_focused
"$CTL" inject "$FIXTURES/silence.wav" >/dev/null || fail "inject silence"
"$CTL" await-state inserted --timeout 60 >/dev/null || fail "silence never reached inserted"
sleep 0.4
if [ -s "$PROBE_OUT" ]; then fail "silence inserted text: $(cat "$PROBE_OUT")"; fi
echo "e2e: silence.wav OK (nothing inserted)"

run_case the_quick_brown_fox.wav "the quick brown fox jumps over the lazy dog"
run_case numbers.wav "testing 123"

# 6) Clipboard restored to the sentinel (best-effort restore, SPEC §8.4).
sleep 0.5
RESTORED="$(pbpaste)"
[ "$RESTORED" = "$SENTINEL" ] || fail "clipboard not restored: got \"$RESTORED\""
echo "e2e: clipboard restore OK"

# 7) OPTIONAL real-hotkey smoke (SPEC §10.4 layer 6, non-blocking): synthetic Ctrl+Space starts
#    a real MIC recording; second chord stops it. Runs with the probe focused so any ambient
#    speech lands there and nowhere else. Ambient silence → VAD gate → empty insert.
hotkey_smoke() {
  local post="$MURMUR_REPO/build/postkeys"
  if [ ! -x "$post" ]; then
    swiftc -O -o "$post" "$MURMUR_REPO/scripts/postkeys.swift" 2>/dev/null || return 1
  fi
  clear_probe
  assert_probe_focused
  "$post" >/dev/null || return 1
  local up=""
  for _ in $(seq 1 20); do
    if "$CTL" health | grep -q '"recording":true'; then up=1; break; fi
    sleep 0.2
  done
  [ -n "$up" ] || { echo "e2e: hotkey smoke — recording never started" >&2; return 1; }
  sleep 1.2
  "$post" >/dev/null || return 1
  "$CTL" await-state inserted --timeout 60 >/dev/null || {
    echo "e2e: hotkey smoke — never reached inserted" >&2; return 1; }
  echo "e2e: hotkey smoke OK (tap fired, mic session completed)"
}
if [ "${MURMUR_E2E_HOTKEY:-1}" = "1" ]; then
  hotkey_smoke || echo "e2e: WARN hotkey smoke failed (non-blocking; tap flakiness is a known headless risk)"
fi

# 8) No error-level logs in a clean run (SPEC §10.6).
if grep -q '"level":"error"' "$MURMUR_HOME/logs/murmur.log" 2>/dev/null; then
  grep '"level":"error"' "$MURMUR_HOME/logs/murmur.log" >&2
  fail "error-level log lines in a clean e2e run"
fi
echo "e2e: no error-level logs"

echo "e2e: PASS"
