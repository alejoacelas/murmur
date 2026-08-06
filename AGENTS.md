---
human_edit_tracking:
  enabled: true
  history: []
---
# For the implementing agent

You are building **Murmur** from [SPEC.md](SPEC.md) (v2; see [REDTEAM.md](REDTEAM.md) for why it's
shaped this way). Read the whole spec first, then re-read [§0 Verification spikes](SPEC.md#0-verification-spikes-do-these-first)
and [§10 Autonomous testing](SPEC.md#10-autonomous-testing) — §0 gates everything (do the spikes,
especially S1–S3 on the FluidAudio API, **before writing any app code**), and §10 defines your build
seams and definition of done.

## Ground rules
- **The human does zero manual testing.** You must verify everything yourself on the Mac you're
  running on. Build the testability seams (control socket, `murmurctl`, audio injection, headless
  `transcribe`, JSON logs) *before* the UI, so you can drive the app without a mic or keyboard.
- **Full permissions available.** Use `scripts/grant-permissions.sh` to pre-grant Microphone,
  Input Monitoring, and Accessibility, and a stable self-signed cert so grants survive rebuilds.
- **Test with `MURMUR_TRIGGER=ctrl-space`** — non-Fn, deterministic, and Wispr Flow owns `Fn` here.
  Production `Fn`+`Space` is *pending spikes S6/S7*. Note `open` won't pass env vars (S8): launch the
  bundle exec directly or write `config.json`. Drive most tests through the control socket, not the tap.
- **Keep it minimal.** Build only the five "Must have" items in §1. Anything in "out of scope"
  stays out. A smaller app that nails the five is the goal.

## Definition of done
Meet every checkbox in [§10.6](SPEC.md#106-one-command-harness--acceptance). In particular:
`scripts/test.sh` (build → sign → grant → unit tests → launch → e2e-into-TextEdit → teardown)
must pass **10 consecutive runs**, and the launch-recovery test (SIGKILL mid-transcription,
relaunch, session auto-completes from saved audio) must pass.

## Build order (each milestone is independently testable — see §12)
0. **Spikes (§0).** Verify the fragile assumptions — FluidAudio API (S1–S3), Fn/paste/`open`/TCC
   (S6–S11), crash recovery (S12) — and fix the spec if any fail. No app code before S1–S3 pass.
1. Backend: `murmur-smoke <wav>` on the fixtures. No GUI, no permissions.
2. Record loop headless: `AudioSource`/`Recorder`/`SessionStore` + `murmurctl inject`, crash-safe
   CAF, retry + launch-recovery.
3. Insertion + control socket: paste into TextEdit, e2e test green.
4. Hotkey + menu bar + live-transcript HUD.
5. Harden: run `scripts/test.sh` ×10, fix flakiness, meet every §10.6 box.

Commit per milestone. When something in the spec is ambiguous, make the reasonable call, flag it
in the commit message, and keep going — don't wait on the human.
