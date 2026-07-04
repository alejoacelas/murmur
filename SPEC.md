# Murmur — implementation spec (v2)

> Working name is **Murmur** (ties to Parakeet, short, avoids colliding with macOS's own
> "Dictation"). Rename is a find-and-replace; don't let the name block you.
>
> **v2** incorporates a `gpt-5.4-pro` red-team of v1. Every accepted, tempered, and rejected
> finding is recorded in [REDTEAM.md](REDTEAM.md) with rationale — read it to see *why* the spec
> looks the way it does.

A minimal, local-first macOS dictation app. A Wispr Flow / FluidVoice alternative that does
**one thing**: press a hotkey, speak, and the transcript lands at your cursor — transcribed
entirely on-device with NVIDIA Parakeet. No cloud, no account, no transcript "cleanup" by default.

This document is the complete build spec, written so a coding agent can implement and
**autonomously test the app to reliability with zero manual testing by a human**. Two sections
gate everything else — **read them before writing any app code**:
- [§0 Verification spikes](#0-verification-spikes-do-these-first) — probes that must pass before
  the design is trustworthy. Several v1 assumptions were unverified; §0 makes the agent verify
  them and rewrite the spec if any fail.
- [§10 Autonomous testing](#10-autonomous-testing) — the testability seams that shape the
  architecture.

---

## 0. Verification spikes (do these first)

**Milestone 0. No app/UI code until these pass.** Each probe checks a v1 assumption that, if
wrong, changes the design. If a probe fails, fix the spec (and note it in REDTEAM.md) before
building. Run on the **actual target Mac, in an active GUI login session** (not SSH-only).

| # | Verifies | Probe (abbreviated — full commands in [`spikes/`](#11-project-layout)) | If it fails |
|---|---|---|---|
| S1 | **FluidAudio public API exists** as assumed | Build a throwaway SwiftPM pkg depending on `exact: "0.12.4"`; `rg` the checkout for `AsrManager`, `AsrModels.downloadAndLoad`, `SlidingWindowAsrManager`, `ASRConfig`, `resampleAudioFile`, `transcribe`, `case v2/v3`. | Rewrite §2/§8 against the real symbols. |
| S2 | **End-to-end batch transcribe** of a fixture WAV works | 20-line spike using the discovered API → non-empty transcript. | Backend is not viable as specced. |
| S3 | **`transcribe` signature** — does upstream take a `source:` arg? | Inspect the real method signature. (v1 assumed `transcribe(_:source:)`; upstream README shows `transcribe(samples)`. The `source:` form is from FluidVoice's *fork*.) | Use the real signature; drop `source:`. |
| S4 | **Model download is deterministic + cacheable** | Time first vs second `ensure-model` into a fixed cache dir; checksum files. Second run must not re-download/recompile. | Add caching/pinning; treat download as bootstrap, not per-run. |
| S5 | **Streaming partials API exists** and accepts your buffer shape | Tiny file-stream spike → partial callbacks fire. | HUD partials become "deferred"; batch-only for v1. |
| S6 | **Fn/Globe event semantics** on this hardware | `spikes/fnprobe.swift`: a listen-only tap printing `type/keycode/flags` for Fn, Fn+Space, L-Opt+Space, R-Opt+Space. | Fix §4 to match observed flags/keycodes. |
| S7 | **Fn+Space is swallowable** before macOS acts on it | Swallow probe returns `nil` on Fn+Space; focus TextEdit, press it → no space, no input-source switch, no emoji panel. | Fn+Space is not a safe default; ship a different production hotkey. |
| S8 | **`open` does NOT pass env vars** to the app | `MURMUR_TRIGGER=x open -na Murmur.app` then inspect the process env. | Confirmed-failing → launch the bundle exec directly or write config to disk (the spec assumes this; see §10.2). |
| S9 | **Automation TCC blocks AppleScript readback** | `osascript -e 'tell application "TextEdit" to get name of document 1'` → expect prompt / `-1743`. | Confirms why v2 uses `InsertionProbe.app` instead (§10.5). |
| S10 | **PPPC profile install** works on this machine | `sudo profiles install …`; query TCC.db for the grants. | If it fails (unmanaged Mac), permissions must be granted by a human once at bootstrap (§10.1). |
| S11 | **Self-signed cert keeps the designated requirement stable** across rebuilds | `codesign -d -r-` before/after a rebuild+resign; `diff`. | TCC grants won't persist; fix cert/bundle-id stability (§9). |
| S12 | **Killed-writer CAF is recoverable** | Recorder-probe writes CAF; `kill -9` mid-write; `afinfo`/`afconvert` the partial file. | Crash-safety story needs redesign (§5.3). |
| S13 | **Tests run in a real GUI session** (+ Secure Input off) | `launchctl print gui/$UID`; check `IOHIDSystem` `SecureInput`. | Event taps / posting will misbehave; fix the environment, not the app. |

S1–S3 and S6–S9 are the highest-value; do them first. The spike sources live in `spikes/` and are
throwaway — none ship in the app.

---

## 1. Scope

### Must have (the whole product)
1. **Local transcription with Parakeet**, model `parakeet-tdt-0.6b-v2` (English) — the only model
   in v1. No audio leaves the machine.
2. **No cleanup step by default.** The raw Parakeet transcript is inserted. No LLM/prompt pass. A
   `TranscriptProcessor` seam exists but ships as a no-op ([§8.3](#83-no-cleanup-by-default)).
3. **Hotkey trigger.** Production default `Fn`+`Space` **pending S6/S7**; a preset non-Fn hotkey
   (`Ctrl`+`Space`) is the fallback and the value used in all testing ([§4](#4-hotkey-engine)).
   Preset triggers only — no custom-recorder UI, no modifier-alone triggers, no hold-to-talk in v1.
4. **Reliable audio persistence with retry.** Every recording is written to an authoritative
   capture artifact during recording, so a failed/crashed transcription retries from saved audio,
   including a crash *mid-recording* ([§7](#7-sessions-persistence--retry)).
5. **Live transcript display** while speaking — a floating pill near the cursor showing streaming
   partials, FluidVoice-style. **Best-effort:** partials drive the HUD only; the text actually
   inserted always comes from the authoritative batch pass ([§6](#6-live-transcript-hud),
   [§8.2](#82-transcription-passes)).

### Explicitly out of scope (keep it minimal)
- Transcript cleanup / LLM enhancement / custom vocabulary.
- Multilingual (`v3`), model switching, cloud providers, Parakeet Flash.
- Custom-hotkey recorder, hold-to-talk, modifier-alone triggers.
- Secure input / password fields (explicitly **unsupported** — [§8.4](#84-text-insertion)).
- History browser, analytics, onboarding beyond the minimum permission flow.
- Windows/Intel. **Apple Silicon only.** Notarization / App Store (ad-hoc/self-signed is fine).

If a feature isn't in "Must have," don't build it. A smaller app that nails the five is the goal.

---

## 2. Target & stack

| Concern | Decision |
|---|---|
| Platform | macOS 14.0+ (Sonoma), Apple Silicon only |
| Language | Swift 6, SwiftUI + AppKit (menu bar `MenuBarExtra`, HUD `NSPanel`) |
| Bundle id | **`com.alejoacelas.murmur`** — fixed. Never let the agent invent one; PPPC/TCC/DR all key on it. |
| Packaging | A **`MurmurKit` library** target holds all logic. Thin executables link it: **`Murmur.app`** (GUI), **`murmurctl`** (CLI client), **`InsertionProbe.app`** (test target, [§10.5](#105-end-to-end-via-the-control-socket)). No dual-mode GUI/CLI binary. |
| Build | SwiftPM from CLI (`swift build`) + a bundling script. **Never require the Xcode GUI.** |
| Transcription | [`FluidAudio`](https://github.com/FluidInference/FluidAudio) — Parakeet on the Apple Neural Engine (CoreML). **No Python.** Hidden behind a `TranscriptionBackend` protocol ([§8.1](#81-transcription-backend)). |
| Model | `parakeet-tdt-0.6b-v2` (English). Downloaded at first run to a configurable cache dir. CC-BY-4.0 (attribution required). |
| Sandbox | **Off.** Event taps + keystroke synthesis + global hotkey are impossible sandboxed. Hardened Runtime on, mic entitlement, no JIT. |

### Dependencies — pin FluidAudio exactly
```swift
dependencies: [
    // EXACT pin: pre-1.0 packages break API across 0.x; an autonomous build must be reproducible.
    // Bump deliberately, re-run the §0 spikes, never float with `from:`.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
]
```
Everything else is system frameworks (AVFoundation, CoreGraphics, AppKit, SwiftUI, Carbon key codes).

### Configurable paths (no hardcoded `~/Library/...`)
All state lives under a **single root** resolved from `$MURMUR_HOME`, else
`~/Library/Application Support/Murmur/`. The root contains `recordings/`, `logs/`, `models/`
(model cache; also honor FluidAudio's cache override), `control.sock`, `config.json`. **Tests set
`MURMUR_HOME` to a fresh temp dir per run** so runs never pollute each other. The socket path and
model-cache path are independently overridable (`$MURMUR_SOCK`, `$MURMUR_MODEL_CACHE`).

### Why this stack
FluidVoice — the closest reference — is pure Swift on a fork of FluidAudio (CoreML). We copy that
spine minus everything optional; upstream's public API suffices (verify in S1–S3). Batch/final is
the **authoritative** path; streaming partials are a best-effort HUD nicety. Cribbing references:
[FluidVoice](https://github.com/altic-dev/FluidVoice), [MacParakeet](https://github.com/moona3k/macparakeet).

---

## 3. Architecture

```
   Ctrl+Space (test)         ┌──────────────────────────────┐
   Fn+Space (prod, S6/S7)───▶│ HotkeyEngine (CGEventTap)     │ latched-modifier + exact match
                             └──────────────┬───────────────┘ swallow both keyDown & keyUp
                                            │ start()/stop()
   ┌───────────────────┐  canonical 16k     ▼
   │ AudioSource        │  mono Float32   ┌──────────────────────────────────────────┐
   │  Mic  │  File       │───enqueue────▶ │ CaptureWorker (serial actor / ring buffer)│
   └───────────────────┘  (copy only)     │  • append to authoritative capture file   │
        both emit the                     │  • feed streaming transcriber (best-effort)│
        SAME canonical PCM                └──────────────┬────────────────────────────┘
                                                         │ EOF on stop() (async, drained)
                                          ┌──────────────▼───────────────┐
                                          │ SessionStore (dir + meta.json)│  state machine (§7)
                                          └──────────────┬───────────────┘
                          batch pass over authoritative audio (§8.2)
                                          ┌──────────────▼───────────────┐   VAD gate (§5.4)
                                          │ TranscriptionBackend          │──▶ final text
                                          │  (FluidAudio, batch=truth)    │
                                          └──────────────┬───────────────┘
                        focus captured at START (§8.4)   │
                                          ┌──────────────▼───────────────┐
                                          │ TextInserter (paste, focus-   │
                                          │  rechecked; typing fallback)  │
                                          └───────────────────────────────┘

   ControlServer (unix socket) ◀── murmurctl ◀── test harness   |   MenuBarUI + TranscriptHUD
```

### State ownership & concurrency (the v1 race fixes)
- **`AppModel` (`@MainActor`) owns *state only*** — the enum, the current session id, UI. It never
  touches audio buffers or files.
- **The audio tap callback does the minimum: copy the buffer and enqueue it.** No conversion, file
  I/O, logging, or inference in the tap — those cause dropped audio / tap-disable / deadlocks. A
  dedicated **`CaptureWorker`** (serial `actor` or a serial queue draining a ring buffer) does
  conversion, disk append, and streamer feed.
- **Async boundaries are explicit:** `startRecording()`, `stopRecordingAndFinalize() async` (returns
  only after the source has stopped, the pipeline has drained, and the capture file is closed),
  `transcribeFinalized() async`, `insert() async`. State flips on the main actor *after* the data
  step it represents has completed.

### The `AudioSource` seam (most important design decision)
Mic and file injection are interchangeable, so the whole path is deterministic with a known WAV.
Both sources emit the **same canonical format** — 16 kHz mono **Float32** PCM — so nothing
downstream can tell mic from file. **Resampling happens inside `MicAudioSource`, not in the
recorder.** `stop()` is **async / signals EOF** so callers know no more buffers will arrive.

```swift
protocol AudioSource {
    /// Emits canonical 16 kHz mono Float32 PCM until EOF. Buffers are delivered off the main actor.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// Returns after the last buffer has been delivered (source fully drained).
    func stop() async
}
```
`FileAudioSource` replays a WAV's frames through the identical enqueue path; `MicAudioSource` owns
`AVAudioEngine` + the hardware tap + the `AVAudioConverter` to canonical format.

---

## 4. Hotkey engine

`Fn` (Globe) **cannot** be bound via Carbon `RegisterEventHotKey` (the Fn/secondary flag lives only
in CoreGraphics HID flags). The only mechanism is a **`CGEventTap`**, which needs **Input
Monitoring** ([§8.6](#86-permissions)).

### 4.1 Triggers (presets only in v1)
- **Testing + fallback default: `Ctrl`+`Space`, toggle mode** — non-Fn, deterministic, unaffected
  by Wispr Flow owning `Fn`. **All automated tests use this.**
- **Production default: `Fn`+`Space`, toggle** — *pending S6/S7 verification on the real hardware*.
  If S7 shows macOS wins the Fn+Space chord (input-source/emoji), ship `Ctrl`+`Space` as the
  production default too and note it.
- Toggle only (tap on / tap off). No hold-to-talk, no modifier-alone, no custom recorder in v1.

Presets are selected by name from config or `$MURMUR_TRIGGER` (`ctrl-space` | `fn-space`). **Do not
rely on `open` to pass `$MURMUR_TRIGGER`** (S8) — tests launch `Murmur.app/Contents/MacOS/Murmur`
directly, or write `config.json` before launch.

### 4.2 Matching rules (v1 correctness fixes)
- **Match on latched physical-modifier state, not the triggering event's flags.** Track Fn/Ctrl
  down/up from `flagsChanged` (+ keycode); a Space `keyDown` fires only when the latched required
  modifier is currently held. (The Space event's own flags don't always carry the modifier bit.)
- **Exact modifier match, not superset.** `Ctrl`+`Space` must *not* fire on `Cmd`+`Ctrl`+`Space`.
  Normalize to the supported modifier subset and require equality.
- **Swallow both `keyDown` and `keyUp`** of the trigger (return `nil` for each) so no stray space or
  dangling key-up reaches the focused app.
- Handle `.tapDisabledByTimeout` / `.tapDisabledByUserInput` by re-enabling the tap, or the OS
  silently kills it under load.
- `tapCreate` returning `nil` ⇒ Input Monitoring not granted; surface guidance ([§8.6](#86-permissions)) and log.

Key codes: `kVK_Function=0x3F`, `kVK_Space=0x31 (49)`, `kVK_Control=0x3B`, `kVK_ANSI_V=0x09`.
Factor the "does this event match?" decision into a **pure function** over (latched modifiers,
event type, keycode) so it's unit-testable without a live tap ([§10.4](#104-test-layers) layer 3).
Full reference in [Appendix A](#appendix-a-reference-hotkeyengine).

---

## 5. Audio capture

### 5.1 Canonical format & ownership
Everything downstream consumes **16 kHz mono Float32 PCM**. `MicAudioSource` captures at the
hardware format (the input-node tap *must* use the hardware format) and resamples to canonical with
`AVAudioConverter`. The `CaptureWorker` only ever sees canonical buffers; it does not resample.

### 5.2 Engine & real-time safety
`AVAudioEngine` input-node tap. **The tap callback copies the buffer and enqueues it to the
`CaptureWorker`; nothing else.** The worker (off the audio thread) converts if needed, appends to
the capture file, and feeds the streaming transcriber.

### 5.3 Authoritative capture artifact & honest durability
- **The authoritative recording is `audio.caf`** (Core Audio Format — designed for streaming, stays
  valid when truncated, unlike a length-prefixed WAV header). Written continuously via
  `AVAudioFile(forWriting:)`; each `write(from:)` appends.
- **Durability claim, stated precisely:** `AVAudioFile.write` hands bytes to the OS, so audio
  already written **survives a process crash / SIGKILL** (the case that matters for "retry if
  transcription fails") — the OS retains the buffered writes. It is **not** a guarantee against
  power loss. To narrow even that window, call `fsync` on a timer (~every 2 s) during recording.
  **Verify real recoverability with S12** (kill a live writer, `afconvert` the partial), not by
  assuming.
- **`audio.wav` is a derived cache, not the source of truth.** On clean stop, transcode
  `audio.caf → audio.wav` for convenience, but transcription and retry read the **authoritative
  audio**, preferring `audio.caf`; `audio.wav` is optional. Don't oversell `replaceItemAt` as
  crash-durable (with `AVAudioFile` you don't hold the FD, and a rename isn't dir-synced).

### 5.4 Silence / hallucination gate
Parakeet (like most ASR) **hallucinates on silence/noise**. Before the batch pass, compute RMS over
the recording; if below a threshold (tune during testing), **produce no transcript and insert
nothing** — don't feed near-silence to the model. `silence.wav` asserts this path
([§10.3](#103-fixtures--assertions)).

`wavSettings` and the reference `CaptureWorker`/`Recorder` are in [Appendix B](#appendix-b-reference-capture).

---

## 6. Live transcript HUD

Mirror FluidVoice's live preview with a minimal floating pill — but it is a **display nicety, not
the source of inserted text**.
- **Window:** borderless `.nonactivatingPanel` `NSPanel`, `level = .statusBar`,
  `ignoresMouseEvents = true`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary]`, clear bg, shadow, shown via `orderFrontRegardless()` (never steals focus). SwiftUI
  content in `NSHostingView`.
- **Placement:** just below `NSEvent.mouseLocation`. No caret tracking (out of scope).
- **States:** `recording` → animated glyph + streaming partial text; `transcribing` → spinner;
  auto-hide ~0.4 s after insert or on cancel.
- **Testability:** in debug builds, expose the HUD's current visibility and last partial via the
  control API (`murmurctl hud`) so tests can assert it without a screen. If S5 shows streaming is
  version-fragile, ship the HUD showing a "listening…" state without live partials and defer
  partials — the app still meets must-have #5's intent minimally; note the downgrade.

---

## 7. Sessions, persistence & retry

**Audio is sacred; a transcript can always be regenerated. Transcription failure ≠ insertion
failure.**

### 7.1 Layout
Session dir under `$MURMUR_HOME/recordings/<id>/`:
```
audio.caf        # authoritative, written during recording
audio.wav        # derived cache (optional, post-stop)
meta.json        # state machine + result (written atomically on every change)
transcript.txt   # written when transcription succeeds
```

### 7.2 State machine (split states)
```
recording ─▶ recorded ─▶ transcribing ─▶ transcribed ─▶ inserting ─▶ inserted
                │              │               │              │
                ▼              ▼               │              ▼
           (crash mid-    transcribeFailed     │        insertFailed
            recording)      (transient|          └─────────────┐
                             permanent)                        │
                                                     (already have transcript;
                                                      retry = re-insert, NOT re-transcribe)
```
`meta.json` records `state`, `attempts`, `failureClass` (`transient` | `permanent`), `lastError`,
`model`, `durationSec`, timestamps, and (on success) `transcript`.

### 7.3 Retry & recovery rules
- **Transient transcription failures** (model warm-up, transient I/O) → auto-retry up to 3 total
  with backoff. **Permanent failures** (corrupt/empty audio, missing model, unsupported format) →
  no auto-retry; menu shows "Retry" for a manual attempt. Classification is persisted so relaunch
  doesn't thrash on a permanent failure.
- **`insertFailed`** (target lost focus, paste blocked) → retry means **re-insert the existing
  transcript**, never re-transcribe (re-transcribing could duplicate output). Re-check focus first.
- **Crash-mid-recording recovery:** on launch, scan for sessions in `recording` older than a
  staleness threshold, and orphan dirs that have `audio.caf` but incomplete `meta.json`. Finalize
  their audio and transcribe. This is the case v1 missed.
- **Launch recovery** re-runs only recoverable states (`recording`→finalize, `recorded`,
  `transcribing`, `transcribed`→re-insert, transient `transcribeFailed`). Permanent failures wait
  for manual retry.
- **Manual retry:** menu item + `murmurctl retry <id>`.

### 7.4 Retention
Default **keep** audio + transcript after success. Setting `retention`: `keep` | `deleteOnSuccess`
(even then, audio is kept while `state` isn't terminal-success). Optional age-based prune (default off).

---

## 8. Transcription, insertion & config

### 8.1 Transcription backend
Hide FluidAudio behind a protocol so an API change (or a swap to another engine) touches one file:
```swift
protocol TranscriptionBackend {
    func ensureModelReady() async throws          // download+load (idempotent, cached)
    func transcribe(_ samples: [Float]) async throws -> String   // batch/authoritative
    // Optional streaming; nil if S5 not satisfied:
    func makeStreamingSession() -> StreamingSession?
}
```
`FluidAudioBackend` wraps `AsrModels.downloadAndLoad(version: .v2)` +
`AsrManager(config: .default)` + `transcribe(...)` **using the exact signature discovered in S1–S3**
(drop `source:` if upstream lacks it). Load once, keep warm.

### 8.2 Transcription passes
- **Batch pass = authoritative.** On stop, transcribe the full authoritative audio in one pass; its
  output is the **only** text ever inserted. Identical to what a retry produces.
- **Streaming = best-effort HUD only.** If S5 passes, feed live buffers to a `SlidingWindowAsrManager`
  session for partials. **Single warm model where possible;** don't keep two heavyweight managers
  resident if it doubles ANE/memory pressure (v1 risk) — prefer one batch manager plus a
  short-lived/streaming session, or drop streaming to "listening…" per §6.

### 8.3 No cleanup by default
Inserted text is **raw Parakeet output** (it already emits punctuation/caps). Implement
`TranscriptProcessor` with a wired-in `IdentityProcessor` (returns input unchanged). No LLM
dependency, no cleanup config.

### 8.4 Text insertion
- **Focus capture:** record the frontmost app / focused element **at recording start**. Before
  inserting, **re-check focus**; if it changed (common in toggle mode), either target the captured
  app or fail into `insertFailed` safely rather than pasting into the wrong place.
- **Default: paste via synthesized `Cmd`+`V`.** Snapshot the pasteboard, set our string, post
  `Cmd+V`, then **best-effort restore** the previous clipboard after a short, **configurable** delay
  (`preserveClipboard`, default on). Restore is **lossy best-effort** — file promises / custom
  providers don't round-trip via `NSPasteboardItem`; don't claim perfect fidelity. Consider trying
  **AX (`AXUIElement`) insertion** first where available, paste as fallback.
- **Event tap for posting:** probe both `.cgAnnotatedSessionEventTap` and `.cghidEventTap` on real
  apps (S-style check) and standardize on whichever is accepted; keep it configurable for tests.
- **Typing fallback** (`CGEventKeyboardSetUnicodeString`, ~20-char chunks): **ASCII-ish fallback
  only**, fragile with IMEs/emoji/dead-keys; not a "reliable" primary path.
- **Secure input / password fields are unsupported in v1** — Secure Input can block taps, paste, and
  typing wholesale. Detect and no-op with a logged reason.

### 8.5 Config (`$MURMUR_HOME/config.json`, all optional)
```json
{
  "trigger": "ctrl-space",        // ctrl-space | fn-space  (presets only)
  "model": "parakeet-v2",         // v1: parakeet-v2 only
  "insertion": "paste",           // paste | type
  "preserveClipboard": true,
  "retention": "keep"             // keep | deleteOnSuccess
}
```

### 8.6 Permissions
Three **distinct** TCC grants, **gated by feature** — the app is *not* "useless without all three":
file-transcribe needs none; the record path needs Microphone; insertion needs Accessibility; the
hotkey needs Input Monitoring. A status window lists live green/red state + "Open Settings".

| Permission | Needed for | Detect / request |
|---|---|---|
| **Microphone** | mic recording | `AVCaptureDevice.authorizationStatus(for:.audio)` / `requestAccess`. `NSMicrophoneUsageDescription` in Info.plist. |
| **Input Monitoring** | the listening `CGEventTap` | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()`. `tapCreate == nil` ⇒ missing. |
| **Accessibility** | posting keystrokes (paste/type) | `AXIsProcessTrustedWithOptions(prompt:true)`. |

Deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` /
`?Privacy_ListenEvent` / `?Privacy_Accessibility`. After a grant, macOS often needs an **app
relaunch** to see it — detect the flip and prompt to restart. Permission *provisioning* is
**bootstrap, not per-test-run** ([§10.1](#101-permissions-are-bootstrap-not-per-run)).

---

## 9. Build, sign, run

- **No sandbox.** `app-sandbox = false`; Hardened Runtime on with
  `com.apple.security.device.audio-input = true`.
- Build headless: `swift build -c release`; `scripts/bundle.sh` assembles `Murmur.app` (Info.plist
  `LSUIElement = true` → no Dock icon; fixed bundle id `com.alejoacelas.murmur`) and **codesigns
  with a stable self-signed identity** so the **designated requirement is constant across rebuilds
  and TCC grants persist**. No notarization.
- **`scripts/make-cert.sh` (one-time):** create a self-signed code-signing cert (fixed subject) in a
  keychain, and **set the key partition list / keychain ACLs** so `codesign` won't block on prompts
  during automated rebuilds. **Verify stability with S11** (`codesign -d -r-` diff across rebuilds),
  not just "codesign succeeded". Recreating the cert breaks persistence — treat it as durable infra.
- Sign: `codesign --force --options runtime --entitlements Murmur.entitlements --sign "Murmur Dev" Murmur.app`.
- **Launch for tests by exec, not `open`** (S8): `Murmur.app/Contents/MacOS/Murmur` so env
  (`MURMUR_HOME`, `MURMUR_TRIGGER`) is inherited. If Gatekeeper quarantines a copy:
  `xattr -dr com.apple.quarantine Murmur.app`.

`scripts/`: `bundle.sh`, `make-cert.sh`, `grant-permissions.sh`, `reset-permissions.sh`, `run.sh`,
`test.sh`, `preflight.sh` ([§10.6](#106-one-command-harness--acceptance)).

---

## 10. Autonomous testing

**A coding agent on a Mac with full permissions builds this and drives it to reliability with no
human clicking or speaking.** These seams come *first*, before UI. Design changed from v1 in two big
ways: a **purpose-built insertion probe** (no AppleScript/TextEdit), and **permissions treated as
environment bootstrap** rather than something the test loop conjures.

### 10.1 Permissions are bootstrap, not per-run
Grant the three services **once** to the fixed bundle id on a **pre-provisioned machine/VM image**,
then reuse it across runs. The test loop *validates* (`murmurctl permissions` → asserts), it does
not try to grant on an arbitrary Mac.
- Preferred: **PPPC configuration profile** (`assets/murmur.pppc.mobileconfig`) — reliably unattended
  only on **MDM/UAMDM-managed** machines (verify with S10). On an unmanaged Mac, a human grants the
  three toggles once at setup (this is the one upfront human step; flag it).
- Lab-only fallback: **direct TCC.db writes** on a **disposable SIP-disabled** box (schema/tool
  drift; restart `tccd`). Not a portable path — last resort.
- `scripts/reset-permissions.sh` = `tccutil reset {Microphone,Accessibility,ListenEvent} com.alejoacelas.murmur`
  for a clean slate. The **stable cert** (§9) keeps grants across rebuilds within a session.

### 10.2 Control interface — the automation seam
`Murmur.app` runs a **Unix-domain control server** at `$MURMUR_SOCK`
(default `$MURMUR_HOME/control.sock`). **`murmurctl`** sends line-delimited JSON and prints JSON.
This drives the app with **no synthetic keys and no live mic**. Expanded from v1 with readiness,
model, deterministic waits, and fault injection so the harness never `sleep`s blindly:

| Command | Effect / returns |
|---|---|
| `murmurctl health` | `{ready, guiSession, permissions:{mic,input,ax}, model:{state}}` — one-shot readiness |
| `murmurctl wait-ready [--timeout s]` | blocks until app is up + model ready |
| `murmurctl await-state <state> [--timeout s]` | blocks until the state machine reaches `<state>` (deterministic, no sleeps) |
| `murmurctl model status` / `model ensure` | report / trigger idempotent model download+load |
| `murmurctl permissions` | `{microphone,inputMonitoring,accessibility}` |
| `murmurctl start` / `stop` | begin / stop recording from the current source |
| `murmurctl inject <wav>` | one-shot record→transcribe→insert using `<wav>` as source; `{sessionId,transcript}` |
| `murmurctl transcribe <wav>` | headless: transcribe a file, return text (no HUD/insert/session) |
| `murmurctl retry <id>` | re-run a session per its state (re-transcribe or re-insert) |
| `murmurctl last` / `sessions` | session meta / list |
| `murmurctl hud` | (debug) `{visible, lastPartial}` — lets tests assert the HUD |
| `murmurctl quit` | clean shutdown |
| `murmurctl fault <kind> <value>` | (debug) inject faults: `transcribe-delay-ms`, `fail-transcribe`, `fail-insert` — makes race tests deterministic |

`inject` (FileAudioSource) is the e2e workhorse; `transcribe` is the zero-permission backend check.
The **`murmur-smoke`** executable also transcribes a fixture with no GUI/permissions for the earliest
milestone.

### 10.3 Fixtures & assertions
Commit **fixed** WAVs under `Tests/Fixtures/` (16 kHz mono; **do not regenerate in the loop** — `say`
voices drift across macOS versions):
- `hello_world.wav`, `the_quick_brown_fox.wav`, `numbers.wav` (short), `silence.wav`, `long_60s.wav`.
- `scripts/make-fixtures.sh` regenerates them *offline* when deliberately refreshing, via
  `say … | afconvert -f WAVE -d LEI16@16000 -c 1`.

**Assertion policy (WER on tiny clips is meaningless — one wrong word in "hello world" is WER 0.5):**
- **Short clips** → **exact normalized match** (lowercase, strip punctuation, collapse whitespace).
- **`long_60s.wav`** → **WER/CER ≤ threshold** (e.g. WER ≤ 0.1).
- **`silence.wav`** → empty output (VAD gate, §5.4).

### 10.4 Test layers
1. **Backend unit** (no permissions, `murmur-smoke`/`murmurctl transcribe`): fixtures → §10.3 policy.
   Depends on S1–S4. Iterate here until green before any GUI.
2. **Persistence/retry unit:** create sessions; use `fault fail-transcribe` / `transcribe-delay-ms`
   to force paths; assert audio survives, crash-mid-recording recovery finalizes+transcribes,
   transient vs permanent classification, `transcribed`→re-insert (not re-transcribe). Recovery test
   kills a **real writer process** (S12), not a synthetic truncation.
3. **Hotkey logic unit:** call the pure match function with synthetic (latched-modifier, type,
   keycode) sequences for Ctrl+Space and Fn+Space; assert start/stop and exact-match rejection of
   `Cmd+Ctrl+Space`. (Live tap needs Input Monitoring; keep matching pure.)
4. **End-to-end via control socket** (needs the granted permissions + GUI session) — see §10.5.
5. **Clipboard-restore:** sentinel on clipboard → `inject` → assert restored (best-effort; documented).
6. **Real-hotkey smoke (optional, non-blocking):** post synthetic `Ctrl`+`Space` via `CGEvent`, assert
   recording starts — exercises the tap itself; may be flaky headless.

### 10.5 End-to-end via the control socket
No AppleScript, no TextEdit (that adds a **fourth** TCC domain — Automation/AppleEvents — and
first-run/focus flakiness; see S9). Instead ship **`InsertionProbe.app`**: a tiny target with a
focused `NSTextView` that **reports its own text back over the control socket / a file**. The e2e:
1. Launch `Murmur.app` by exec with `MURMUR_HOME=<temp>` `MURMUR_TRIGGER=ctrl-space`.
2. `murmurctl wait-ready`; `murmurctl permissions` → assert all true; `preflight.sh` asserts GUI session.
3. Launch `InsertionProbe.app`, focus its text view.
4. `murmurctl inject Tests/Fixtures/hello_world.wav`; `murmurctl await-state inserted`.
5. Read the probe's text via its readback; assert it matches (§10.3). No mic, no human, deterministic.

**Coverage honesty:** `inject` bypasses the real microphone/`AVAudioEngine` stack. To exercise the
mic path without a human, optionally install a **virtual audio input device** (e.g. BlackHole) as
bootstrap and play a fixture into it; otherwise state plainly that the mic path is covered by
`MicAudioSource` unit tests + one manual smoke, not the automated loop. Don't let the harness's green
imply mic/HUD coverage it doesn't have.

### 10.6 One-command harness & acceptance
`scripts/preflight.sh` fails fast unless: active GUI login session (`launchctl print gui/$UID`),
Secure Input off, the three permissions granted, model present (S13). `scripts/test.sh`: preflight →
build → bundle → sign → unit tests → launch app → e2e (InsertionProbe) → teardown (reset, quit).
Non-zero on any failure, with a summary. **This is the loop the agent runs until green.**

Done when, on the provisioned Mac:
- [ ] Milestone-0 spikes S1–S13 all pass (or the spec was corrected and REDTEAM.md updated).
- [ ] Backend + persistence + hotkey-logic unit tests pass.
- [ ] `scripts/test.sh` e2e passes **10 consecutive runs** (guards tap/paste/timing flakiness).
- [ ] Crash recovery: SIGKILL the app mid-recording **and** mid-transcription (via `fault
      transcribe-delay-ms`), relaunch, session auto-completes from saved audio.
- [ ] `hello_world` / `the_quick_brown_fox` / `numbers` land in InsertionProbe (exact normalized);
      `long_60s` within WER ≤ 0.1; `silence` inserts nothing.
- [ ] No `error`-level logs across a full `test.sh` run except those failure tests intentionally cause.
- [ ] Coverage note filed: what the loop proves vs. what's only unit-tested (mic, HUD) or manual.

---

## 11. Project layout
```
Murmur/
  Package.swift
  Sources/
    MurmurKit/            # ALL logic (library)
      AppModel.swift  (state only, @MainActor)
      Hotkey/HotkeyEngine.swift, TriggerMatch.swift (pure)
      Audio/AudioSource.swift, MicAudioSource.swift, FileAudioSource.swift, CaptureWorker.swift
      Transcribe/TranscriptionBackend.swift, FluidAudioBackend.swift, VAD.swift, TranscriptProcessor.swift
      Session/SessionStore.swift, Session.swift
      Insert/TextInserter.swift, FocusTracker.swift
      Control/ControlServer.swift, Protocol.swift
      Support/Paths.swift (MURMUR_HOME), Log.swift, Config.swift, Permissions.swift
    Murmur/               # GUI executable → MurmurKit
      MurmurApp.swift, UI/MenuBar.swift, UI/TranscriptHUD.swift, UI/PermissionsWindow.swift
    murmurctl/            # CLI client → MurmurKit protocol
    murmur-smoke/         # headless fixture transcribe (earliest milestone)
    InsertionProbe/       # test target: NSTextView + socket readback
  Tests/MurmurTests/ , Tests/Fixtures/*.wav
  spikes/                 # throwaway S1–S13 probes (fnprobe.swift, recorder-probe, api-spike, …)
  scripts/                # bundle, make-cert, grant/reset-permissions, run, test, preflight, make-fixtures
  assets/                 # Murmur.entitlements, Info.plist, murmur.pppc.mobileconfig
  README.md  SPEC.md  REDTEAM.md
```

---

## 12. Milestones
0. **Spikes (§0).** S1–S13 green (highest-value first: S1–S3, S6–S9). No app code before S1–S3 pass.
1. **Backend:** `murmur-smoke <wav>` transcribes fixtures; unit tests green. No GUI/permissions.
2. **Record loop headless:** canonical `AudioSource`/`CaptureWorker`/`SessionStore` + `murmurctl
   inject`; authoritative CAF; split-state retry + crash-mid-recording recovery. Persistence tests green.
3. **Insertion + control socket + InsertionProbe:** paste with focus capture; expanded control API;
   e2e green.
4. **Hotkey + menu bar + HUD:** `CGEventTap` Ctrl+Space (Fn+Space pending S6/S7); menu status; live
   pill (or "listening…" if S5 fails); permissions window.
5. **Harden:** `scripts/test.sh` ×10, fix flakiness, meet every §10.6 box.

Commit per milestone; each is independently testable.

---

## 13. Open guesses (redirect in seconds)
- **Name "Murmur"**, **bundle id `com.alejoacelas.murmur`** — rename freely (bundle id then propagates
  to PPPC/cert/TCC).
- **Test/fallback hotkey = Ctrl+Space; production Fn+Space pending S6/S7.** Say the word to make
  Ctrl+Space (or another) the shipping default outright.
- **Toggle only, English v2 only, keep-audio-forever, 3 transient retries.** All match your setup.
- **Streaming partials best-effort** — if S5 is fiddly, the HUD shows "listening…" and partials are
  deferred. Tell me if live partials are worth blocking on.
- **Mic-path coverage** is unit-tested + optional virtual-device, not in the main e2e loop. Say if
  you want a BlackHole-based mic e2e as a hard requirement.

---

## 14. Attribution & license
- App: MIT.
- Bundles/downloads **NVIDIA Parakeet** (`parakeet-tdt-0.6b-v2`), **CC-BY-4.0** — credit NVIDIA + link
  the model card in README/About.
- **FluidAudio** (Apache-2.0) — credit. Design owes **FluidVoice** (GPLv3) and **MacParakeet** — credit both.

---

## Appendix A reference HotkeyEngine
Session-level `.defaultTap`; bare C callback with `self` via refcon; **latched** Fn/Ctrl edge
tracking from `flagsChanged`; **exact** modifier match; **swallow both keyDown & keyUp**; mandatory
`.tapDisabledByTimeout` re-enable. Keep the match decision in a pure `TriggerMatch` function.

```swift
// Pure, unit-testable core (layer-3 tests call THIS, no live tap):
struct LatchedState { var fnDown = false; var ctrlDown = false /* … */ }
enum TriggerHit { case fire, none }
func triggerHit(_ trigger: Trigger, _ latched: LatchedState,
                type: CGEventType, keyCode: CGKeyCode) -> TriggerHit {
    guard type == .keyDown, keyCode == trigger.keyCode else { return .none }
    // exact match on the latched required modifier set (NOT the event's own flags, NOT superset):
    return trigger.matches(latched) ? .fire : .none
}
```
```swift
// Live tap wiring (adapts v1 Appendix A): track Fn(0x3F)/Ctrl(0x3B) up/down edges from
// flagsChanged into LatchedState; on keyDown call triggerHit(); on a fire, toggle recording and
// return nil; ALSO return nil for the matching keyUp; re-enable on .tapDisabledByTimeout/UserInput.
```

## Appendix B reference capture
Tap callback **enqueues only**; `CaptureWorker` (serial) converts + writes.
```swift
let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                              sampleRate: 16_000, channels: 1, interleaved: false)!
// MicAudioSource: installTap(onBus:0, format: hardwareFormat) { buf, _ in
//     let copy = buf.deepCopy(); worker.enqueue(copy)      // NOTHING else on the audio thread
// }
// CaptureWorker.enqueue → serial actor: AVAudioConverter → canonical → cafFile.write(from:)
//     (append); every ~2s: fsync the CAF fd. Feed streaming session if present.
// stop() async: signal EOF, drain queue, close cafFile, then return.  (WAV transcode is derived.)
let wavSettings: [String: Any] = [   // only for the derived cache artifact
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
]
```
`FileAudioSource` replays a WAV's frames through the same `worker.enqueue` path.

## Appendix C reference TextInserter
Capture focus at start (`FocusTracker`); re-check before insert. Paste: snapshot pasteboard → set
string → post `Cmd`+`V` → best-effort restore after a configurable delay (lossy; documented). Type
fallback: `CGEventKeyboardSetUnicodeString` in ~20-char chunks (ASCII-ish only). Gate on
`AXIsProcessTrustedWithOptions`. Probe `.cgAnnotatedSessionEventTap` vs `.cghidEventTap` and
standardize on the accepted one.
```swift
func insertViaPaste(_ text: String) {   // (adapts v1 Appendix C — add focus re-check + configurable delay)
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
        let c = NSPasteboardItem(); for t in item.types { if let d = item.data(forType: t) { c.setData(d, forType: t) } }; return c
    } ?? []
    pb.clearContents(); pb.setString(text, forType: .string)
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)   // 'v'
    let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
    if Config.preserveClipboard {
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.clipboardRestoreDelay) {
            pb.clearContents(); pb.writeObjects(saved)
        }
    }
}
```
