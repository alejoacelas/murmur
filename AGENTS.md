# For the implementing agent

You are building **Murmur** from [SPEC.md](SPEC.md). Read the whole spec first, then read
[§10 Autonomous testing](SPEC.md#10-autonomous-testing) again — it defines your build seams and
your definition of done.

## Ground rules
- **The human does zero manual testing.** You must verify everything yourself on the Mac you're
  running on. Build the testability seams (control socket, `murmurctl`, audio injection, headless
  `transcribe`, JSON logs) *before* the UI, so you can drive the app without a mic or keyboard.
- **Full permissions available.** Use `scripts/grant-permissions.sh` to pre-grant Microphone,
  Input Monitoring, and Accessibility, and a stable self-signed cert so grants survive rebuilds.
- **Use the dev-override hotkey** `MURMUR_TRIGGER=ropt-space` (Right-Option+Space) while testing —
  Wispr Flow owns `Fn` on this machine. Drive most tests through the control socket, not the tap.
- **Keep it minimal.** Build only the five "Must have" items in §1. Anything in "out of scope"
  stays out. A smaller app that nails the five is the goal.

## Definition of done
Meet every checkbox in [§10.6](SPEC.md#106-one-command-harness--acceptance). In particular:
`scripts/test.sh` (build → sign → grant → unit tests → launch → e2e-into-TextEdit → teardown)
must pass **10 consecutive runs**, and the launch-recovery test (SIGKILL mid-transcription,
relaunch, session auto-completes from saved audio) must pass.

## Build order (each milestone is independently testable — see §12)
1. Backend: `murmur transcribe <wav>` on the fixtures. No GUI, no permissions.
2. Record loop headless: `AudioSource`/`Recorder`/`SessionStore` + `murmurctl inject`, crash-safe
   CAF, retry + launch-recovery.
3. Insertion + control socket: paste into TextEdit, e2e test green.
4. Hotkey + menu bar + live-transcript HUD.
5. Harden: run `scripts/test.sh` ×10, fix flakiness, meet every §10.6 box.

Commit per milestone. When something in the spec is ambiguous, make the reasonable call, flag it
in the commit message, and keep going — don't wait on the human.
