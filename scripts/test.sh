#!/usr/bin/env bash
# test.sh — the one-command harness (SPEC §10.6): preflight → build → bundle → sign → unit
# tests → launch → e2e → teardown. Non-zero on any failure. `test.sh N` repeats the e2e N times
# (the §10.6 acceptance box runs it ×10 to shake out tap/paste/timing flakiness).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

E2E_RUNS="${1:-1}"

echo "== preflight =="
bash "$MURMUR_REPO/scripts/preflight.sh"

echo "== build =="
(cd "$MURMUR_REPO" && swift build 2>&1 | tail -1)

echo "== cert + bundle + sign =="
bash "$MURMUR_REPO/scripts/make-cert.sh"
bash "$MURMUR_REPO/scripts/bundle.sh" "$MURMUR_REPO/.build/debug/Murmur" "$MURMUR_REPO/.build/debug/murmurctl"
bash "$MURMUR_REPO/scripts/bundle-probe.sh"

echo "== unit tests =="
UNIT_HOME="$(mktemp -d /tmp/murmur-unit.XXXXXX)"
trap 'rm -rf "$UNIT_HOME"' EXIT
(cd "$MURMUR_REPO" && MURMUR_HOME="$UNIT_HOME" swift test 2>&1 \
  | grep -E "Test Suite '(All tests|.*Tests)' (passed|failed)|Executed.*failures" | tail -8)

echo "== e2e ×$E2E_RUNS =="
for i in $(seq 1 "$E2E_RUNS"); do
  echo "-- e2e run $i/$E2E_RUNS --"
  bash "$MURMUR_REPO/scripts/e2e.sh"
done

echo "test.sh: ALL GREEN (unit + e2e×$E2E_RUNS)"
