# Murmur — implementation spec

> Working name is **Murmur** (ties to Parakeet, short, avoids colliding with macOS's own
> "Dictation"). Rename is a find-and-replace; don't let the name block you.

A minimal, local-first macOS dictation app. A WisprFlow / FluidVoice alternative that does
**one thing**: press a hotkey, speak, and the transcript lands at your cursor — transcribed
entirely on-device with NVIDIA Parakeet. No cloud, no account, no transcript "cleanup" by
default.

This document is the complete build spec. It is written so a coding agent can implement and
**autonomously test the app to reliability with zero manual testing by a human** (see
[§10 Autonomous testing](#10-autonomous-testing)). Read that section before writing code —
the testability seams it requires shape the architecture.

---

## 1. Scope

### Must have (the whole product)
1. **Local transcription with Parakeet**, default model `parakeet-tdt-0.6b-v2` (English). No
   audio ever leaves the machine.
2. **No cleanup step in the default config.** The raw Parakeet transcript is what gets
   inserted. No LLM/prompt-dictation pass. (A cleanup hook may exist in code but is **off**
   and unconfigured by default — see [§8.3](#83-no-cleanup-by-default).)
3. **Hotkey trigger: `Fn`+`Space`.** Configurable. Ships with a **dev-override** hotkey so the
   implementing agent can test while WisprFlow still owns `Fn` (see [§4](#4-hotkey-engine)).
4. **Reliable audio persistence with retry.** Every recording is written to disk in a
   crash-safe format *before and during* transcription, so a failed/crashed transcription can
   always be retried from the saved audio (see [§7](#7-sessions-persistence--retry)).
5. **Live transcript display** while speaking — a floating pill near the cursor showing the
   streaming partial transcript, the way FluidVoice does (see [§6](#6-live-transcript-hud)).

### Explicitly out of scope (keep it minimal)
- Transcript cleanup / LLM enhancement / custom vocabulary UI. (Leave a seam, ship it off.)
- Multiple simultaneous models, model marketplace, cloud transcription providers.
- History browser, analytics, onboarding wizard beyond the minimum permission flow.
- Windows/Intel support. **Apple Silicon only.**
- Notarization / App Store / signed distribution. This is a personal app; ad-hoc/self-signed
  is fine ([§9](#9-build-sign-run)).

If a feature isn't in "Must have," don't build it. Prefer a smaller app that is rock-solid on
the five things above.

---

## 2. Target & stack

| Concern | Decision |
|---|---|
| Platform | macOS 14.0+ (Sonoma), Apple Silicon only |
| Language | Swift 6, SwiftUI + AppKit (menu bar via `MenuBarExtra`, HUD via `NSPanel`) |
| Build | Swift Package Manager, driven from CLI (`swift build`). An Xcode project is optional; **CI/agent testing must work from `swift build` + a bundling script** — do not require the Xcode GUI. |
| Transcription | [`FluidAudio`](https://github.com/FluidInference/FluidAudio) (Apache-2.0) — Parakeet compiled to CoreML, runs on the Apple Neural Engine. **No Python.** |
| Model | `parakeet-tdt-0.6b-v2` (English) default; `-v3` (multilingual, 25 langs) selectable. Downloaded at first run, not bundled. CC-BY-4.0 (attribution required). |
| Sandbox | **Off.** Event taps + keystroke synthesis + global hotkey are impossible under App Sandbox. Hardened Runtime on, with mic + JIT-free entitlements. |

### Why this stack
FluidVoice — the closest reference app — is pure Swift on a fork of FluidAudio (CoreML), with
Whisper as a secondary backend. We copy that spine minus everything optional. The upstream
public `FluidAudio` API is sufficient; no fork needed. Reference implementations to crib from:
- [FluidVoice](https://github.com/altic-dev/FluidVoice) — Swift, FluidAudio, dual streaming+final managers.
- [MacParakeet](https://github.com/moona3k/macparakeet) — smaller open Mac dictation app on FluidAudio CoreML.

### Dependencies (`Package.swift`)
```swift
dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    // Swift-argument-parser for the CLI subcommands (§10.2). No other runtime deps.
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
]
```
Keep the dependency list this short. Everything else is system frameworks (AVFoundation,
CoreGraphics, AppKit, SwiftUI, Carbon for key codes).

---

## 3. Architecture

```
                         ┌──────────────────────────────────────────┐
   Fn+Space  ───────────▶│  HotkeyEngine  (CGEventTap)              │
   (or dev override)      └───────────────┬──────────────────────────┘
                                          │ start()/stop()
                                          ▼
   ┌────────────┐   16kHz mono buffers   ┌──────────────┐   partials   ┌───────────────┐
   │ AudioSource│──────────────────────▶│ Recorder      │─────────────▶│ Transcription  │
   │  Mic│File  │   (also written to     │ (CAF on disk) │              │ Engine         │
   └────────────┘    disk continuously)  └──────┬───────┘  final audio  │ (FluidAudio)   │
                                                │                        └──────┬────────┘
                                                ▼                                │
                                        ┌───────────────┐   partial text  ┌──────▼──────┐
                                        │ SessionStore   │◀───────────────│ TranscriptHUD│
                                        │ (dir + meta)   │                │ (NSPanel)    │
                                        └──────┬─────────┘  final text     └─────────────┘
                                               │                                 │
                                               │            final text           ▼
                                               │                          ┌──────────────┐
                                               └─────────────────────────▶│ TextInserter │
                                                                          │ (paste Cmd-V)│
                                                                          └──────────────┘

   ┌─────────────┐    control commands (start/stop/inject/retry/status/last-transcript)
   │ControlServer│◀──── Unix domain socket ────  murmurctl CLI  ◀──── autonomous test harness
   └─────────────┘
   ┌─────────────┐
   │ MenuBarUI   │  status icon, Start/Stop, Retry failed, Settings, Quit
   └─────────────┘
```

**Central state machine** (`AppModel`, `@MainActor`): `idle → recording → transcribing →
(inserting) → idle`, with `transcribing → failed` on error. Every transition is logged as a
structured JSON line (see [§10.4](#104-observability)) and reflected in the menu bar icon and
`SessionStore`. Exactly one active session at a time; a second start while non-idle is ignored
(and logged).

**The `AudioSource` protocol is the single most important design seam.** The mic and a
file-injection source are interchangeable behind it, so the entire record→transcribe→insert
path can be exercised deterministically with a known WAV. Never read the mic directly outside
`MicAudioSource`.

```swift
protocol AudioSource {
    /// Emits 16 kHz mono Float PCM frames until `stop()`. Called on an audio thread.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}
```

---

## 4. Hotkey engine

The `Fn` (Globe) key **cannot** be bound with Carbon `RegisterEventHotKey` — the Fn/secondary
flag exists only in the CoreGraphics HID flag space. The only viable mechanism is a
**`CGEventTap`**. This requires the **Input Monitoring** permission ([§8](#86-permissions)).

### 4.1 Behavior
- **Default trigger: `Fn`+`Space`, toggle mode** — tap once to start, tap again to stop. Toggle
  (not hold-to-talk) is the default because it lets you step away from the keyboard during long
  dictations. Hold-to-talk is a setting.
- The trigger event is **swallowed** (tap uses `.defaultTap`, returns `nil` for the match) so no
  literal space is typed into the focused app.
- A **dev-override** trigger is selectable via config/env so the app can be developed and tested
  while WisprFlow still owns `Fn`. Default dev override: **Right-Option (`⌥`) + `Space`**.

### 4.2 Configurable trigger
```swift
struct Trigger: Codable {
    var usesFn: Bool                 // require the secondary-Fn flag
    var modifierFlags: UInt64        // CGEventFlags rawValue, e.g. .maskAlternate
    var keyCode: UInt16?             // kVK_Space = 49; nil = modifier-alone trigger
    var mode: Mode                   // .toggle | .holdToTalk
    enum Mode: String, Codable { case toggle, holdToTalk }

    static let fnSpace     = Trigger(usesFn: true,  modifierFlags: 0, keyCode: 49, mode: .toggle)
    static let rOptSpace   = Trigger(usesFn: false, modifierFlags: CGEventFlags.maskAlternate.rawValue, keyCode: 49, mode: .toggle)
    static let ctrlSpace   = Trigger(usesFn: false, modifierFlags: CGEventFlags.maskControl.rawValue,   keyCode: 49, mode: .toggle)
}
```
Resolution order at launch: `MURMUR_TRIGGER` env var (`fn-space` | `ropt-space` | `ctrl-space`)
→ `~/Library/Application Support/Murmur/config.json` → default `.fnSpace`. **The autonomous
test harness sets `MURMUR_TRIGGER=ropt-space`** (and mostly drives via the control socket
anyway, so it rarely depends on the physical hotkey).

Key codes: `kVK_Function=0x3F`, `kVK_Space=0x31 (49)`, `kVK_ANSI_V=0x09`, `kVK_RightOption=0x3D`.

### 4.3 Implementation notes (from research, use verbatim as the base)
- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
  eventsOfInterest: keyDown|keyUp|flagsChanged, callback:, userInfo: self)`.
- The callback is a bare C function pointer — pass `self` via `userInfo` and
  `Unmanaged.fromOpaque`. No Swift closure capture.
- Track `Fn` via `flagsChanged` where key code == `0x3F` and `flags.contains(.maskSecondaryFn)`;
  down edge = flag now set, up edge = flag now clear.
- `Fn`+`Space` = a `keyDown` for key code 49 while tracked `fnIsDown == true`.
- **Handle `.tapDisabledByTimeout`/`.tapDisabledByUserInput` by re-enabling the tap**
  (`CGEvent.tapEnable(tap:enable:true)`), or the OS silently kills it under load.
- If `tapCreate` returns `nil`, treat it as "Input Monitoring not granted," surface the guidance
  in [§8](#86-permissions), and log it.

The full reference `HotkeyEngine` (with `flagsChanged` edge tracking, toggle vs hold logic, and
tap re-enable) is in [Appendix A](#appendix-a-reference-hotkeyengine).

---

## 5. Audio capture

### 5.1 Format
Parakeet wants **16 kHz, mono, 16-bit PCM**. Capture at the hardware format (the input node tap
*must* use the hardware format) and resample to 16 kHz mono with `AVAudioConverter`.

### 5.2 Engine
Use **`AVAudioEngine`** with a tap on the input node (not `AVAudioRecorder` — we need live
buffers to stream to both the transcriber and the disk file). Each converted buffer is:
1. Handed to the streaming transcriber (partials).
2. Appended to the on-disk recording file.

### 5.3 Crash-safe on-disk format — **CAF while recording, WAV at the end**
A WAV/RIFF header stores total length up front, so a process that dies mid-recording leaves a
WAV whose header lies about its length — often unreadable. **CAF (Core Audio Format) is designed
for streaming and stays valid when truncated.** Therefore:

- During recording, stream to `audio.caf` via `AVAudioFile(forWriting:)`. Each `write(from:)`
  appends and flushes, so captured audio is on disk continuously.
- On clean stop, transcode `audio.caf → audio.wav` **atomically**: write to a temp path, `fsync`
  the handle, then `FileManager.replaceItemAt` to swap into place. Readers never see a partial
  file.
- **Keep `audio.caf` until transcription succeeds.** If the app crashes anywhere in the pipeline,
  a valid CAF remains for retry ([§7](#7-sessions-persistence--retry)).

`wavSettings` and the reference `Recorder` (tap install, `AVAudioConverter` resample loop,
atomic finalize) are in [Appendix B](#appendix-b-reference-recorder).

---

## 6. Live transcript HUD

Mirror FluidVoice's live preview with a minimal floating pill.

- **Window:** borderless `.nonactivatingPanel` `NSPanel`, `level = .statusBar`,
  `ignoresMouseEvents = true`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary]`, clear background, shadowed. Shown with `orderFrontRegardless()` so it never
  steals focus from the app you're dictating into. Content is a SwiftUI view in an
  `NSHostingView`.
- **Placement:** just below the current mouse location (`NSEvent.mouseLocation`, minus ~60pt in
  y). Good enough; do not attempt caret tracking (out of scope).
- **Content / states:**
  - `recording` — animated waveform/mic glyph + the **streaming partial transcript** text,
    updated live as FluidAudio's streaming manager emits partials.
  - `transcribing` — spinner + "Transcribing…" (the short final-pass gap after you stop).
  - Auto-hide ~0.4s after text is inserted, or immediately on cancel.
- The partial text comes from the **streaming** transcription manager; the text actually
  inserted comes from the **final** pass ([§8.2](#82-streaming--final-two-pass)).

Keep it small and legible; no settings for size/position in v1 (FluidVoice has notch/pill/large
modes — out of scope).

---

## 7. Sessions, persistence & retry

This is the reliability backbone. **Audio is sacred; a transcript can always be regenerated.**

### 7.1 Layout
Each recording is a **session directory** under
`~/Library/Application Support/Murmur/recordings/`:
```
recordings/
  2026-07-04T18-22-05_3F2A9C/
    audio.caf        # streaming-safe, written during recording
    audio.wav        # finalized 16kHz mono, written on clean stop
    meta.json        # session state machine + result
    transcript.txt   # written on success
```
`meta.json`:
```json
{
  "id": "2026-07-04T18-22-05_3F2A9C",
  "createdAt": "2026-07-04T18:22:05Z",
  "state": "recorded|transcribing|done|failed",
  "model": "parakeet-tdt-0.6b-v2",
  "durationSec": 7.4,
  "attempts": 1,
  "lastError": null,
  "transcript": "…",            // mirror of transcript.txt on success
  "insertedAt": "2026-07-04T18:22:13Z"
}
```
Write `meta.json` atomically (temp + rename) on **every** state change.

### 7.2 State machine & retry rules
- `recording` ends → CAF finalized to WAV, `state = recorded`.
- Transcription starts → `state = transcribing`, `attempts += 1`.
- Success → write `transcript.txt`, `state = done`, insert text.
- Failure (model error, crash caught, timeout) → `state = failed`, `lastError` set. **Do not
  delete audio.**
- **Automatic retry:** on failure, retry up to **2** more times immediately (total 3 attempts)
  with a short backoff. If still failing, leave `failed` and surface "Retry failed transcription"
  in the menu bar.
- **Recovery on launch:** at startup, scan `recordings/` for any session in `recorded`,
  `transcribing`, or `failed` (i.e. not `done`). Re-run transcription for each from its saved
  audio. This is what makes "retry if something fails" hold across crashes and restarts.
- **Manual retry:** menu item + `murmurctl retry <id>` re-runs a specific session.

### 7.3 Retention
Default: **keep audio and transcript** after success (the user keeps recordings in their
FluidVoice setup). Setting `retention`: `keep` (default) | `deleteOnSuccess`. Even with
`deleteOnSuccess`, audio is kept while `state != done`. Optional cap: prune `done` sessions
older than N days (default off).

---

## 8. Transcription & config

### 8.1 Model management
- On first run, download the default model via `AsrModels.downloadAndLoad(version: .v2)` to
  `AsrModels.defaultCacheDirectory(...)`. Show progress in the menu bar / a small window.
- Load once at launch (or lazily on first record) and keep the `AsrManager` warm — model load is
  the slow part; transcription itself is ~100–190× real-time on Apple Silicon.
- Setting `model`: `parakeet-v2` (English, default) | `parakeet-v3` (multilingual). Maps to
  FluidAudio `.v2` / `.v3`.

### 8.2 Streaming + final (two-pass)
Follow FluidVoice's design: keep **two managers**.
- **Streaming manager** (`SlidingWindowAsrManager` or streaming config) — fed live buffers during
  recording, drives the HUD partials. Optimized for latency, not final accuracy.
- **Final manager** (`AsrManager(config: .default)`) — on stop, transcribe the finalized WAV in
  one pass for the **text that actually gets inserted**. Higher accuracy.

If the two-manager setup proves fiddly for v1, an acceptable fallback is: stream partials for the
HUD, but on stop **re-transcribe the whole WAV** with the batch manager for the inserted text.
The inserted text must always come from a full-file pass over the saved audio, so it's identical
to what a retry would produce.

### 8.3 No cleanup by default
The inserted text is the **raw Parakeet output** — Parakeet v2/v3 already emit punctuation and
capitalization. There is **no** LLM/prompt pass in the default config. Implement a
`TranscriptProcessor` protocol with a default `IdentityProcessor` (returns input unchanged) so a
future cleanup step is a drop-in, but ship `IdentityProcessor` wired in and no cleanup config
present. Do not add an Anthropic/OpenAI dependency.

### 8.4 Text insertion
- **Default: paste via synthesized `Cmd`+`V`.** Set `NSPasteboard` string, post `Cmd+V` via
  `CGEvent`, then **restore the previous clipboard after ~150ms** (restoring synchronously races
  the paste). Snapshot all pasteboard items to restore faithfully.
- **Fallback (setting): type via `CGEventKeyboardSetUnicodeString`** for apps that block paste
  (password fields, some VMs). Chunk the text (~20 chars) with tiny sleeps.
- Both require **Accessibility** permission; without it `CGEvent.post` silently no-ops.
- Reference code for both in [Appendix C](#appendix-c-reference-textinserter).

### 8.5 Config file
`~/Library/Application Support/Murmur/config.json`, all optional with the defaults above:
```json
{
  "trigger": "fn-space",          // fn-space | ropt-space | ctrl-space | {custom struct}
  "triggerMode": "toggle",        // toggle | holdToTalk
  "model": "parakeet-v2",         // parakeet-v2 | parakeet-v3
  "insertion": "paste",           // paste | type
  "retention": "keep"             // keep | deleteOnSuccess
}
```

---

### 8.6 Permissions

Three **distinct** TCC grants. Detect → request → guide the user (deep-link to the exact
Settings pane). The app is useless without all three; show a single status window listing them
with live green/red state and "Open Settings" buttons.

| Permission | Why | API to detect / request |
|---|---|---|
| **Microphone** | record audio | `AVCaptureDevice.authorizationStatus(for:.audio)` / `requestAccess`. Needs `NSMicrophoneUsageDescription` in Info.plist. |
| **Input Monitoring** | the *listening* CGEventTap | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()`. If `tapCreate` returns nil → this is missing. |
| **Accessibility** | *posting* keystrokes (paste/type) | `AXIsProcessTrustedWithOptions(prompt:true)`. |

Deep links:
`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` /
`?Privacy_ListenEvent` / `?Privacy_Accessibility`.

> After granting Accessibility / Input Monitoring, macOS often requires an **app relaunch** for
> the running process to see the grant. Detect the flip and prompt to restart.

Ad-hoc rebuilds change the signature and can re-trigger prompts every build. Fix by using a
**stable self-signed identity** so TCC grants persist across rebuilds — see
[§9](#9-build-sign-run) and [§10.1](#101-permission-automation).

---

## 9. Build, sign, run

- **No sandbox.** `com.apple.security.app-sandbox = false`. Hardened Runtime on with
  `com.apple.security.device.audio-input = true`.
- Build headless: `swift build -c release`, then a `scripts/bundle.sh` assembles `Murmur.app`
  (Info.plist with `LSUIElement = true` for no Dock icon, the binary, entitlements) and
  **codesigns with a stable local identity** (see below). No notarization.
- **Stable self-signed cert (do this once on the test Mac):** create a self-signed code-signing
  certificate in the login keychain named e.g. `Murmur Dev` so the bundle's designated
  requirement is constant across rebuilds and **TCC grants stick**. `scripts/make-cert.sh`
  automates it (`security create-keychain` / a `certtool`/`openssl`+`security import` flow, or a
  documented Keychain Access step). Falling back to ad-hoc (`--sign -`) works but re-prompts for
  permissions on every rebuild — acceptable only if [§10.1](#101-permission-automation)
  re-grants each build.
- Sign: `codesign --force --options runtime --entitlements Murmur.entitlements --sign "Murmur Dev" Murmur.app`.
- If Gatekeeper quarantines a copied build: `xattr -dr com.apple.quarantine Murmur.app`.

`scripts/` to provide: `bundle.sh`, `make-cert.sh`, `grant-permissions.sh`,
`reset-permissions.sh`, `run.sh` (build → bundle → sign → launch).

---

## 10. Autonomous testing

**The whole point: a coding agent on a different Mac, with full admin/permissions, builds this
and drives it to reliability without a human ever clicking anything or speaking into a mic.**
Every requirement below exists to make that possible. Build these seams *first*.

### 10.1 Permission automation
The test Mac has full permissions and (for the deepest automation) may have **SIP disabled in a
disposable VM/box**. Provide:
- `scripts/grant-permissions.sh` — grants Microphone, Input Monitoring, Accessibility to the
  Murmur bundle id. Two supported mechanisms, pick per environment:
  1. **PPPC configuration profile** (`assets/murmur.pppc.mobileconfig`, no SIP change) installed
     via `profiles install` / MDM — the sanctioned path. Payload authorizes
     `kTCCServiceAccessibility`, `kTCCServiceListenEvent`, `kTCCServiceMicrophone` for the
     bundle id + its (stable self-signed) code requirement.
  2. **Direct TCC.db writes** for a SIP-disabled test box (`auth_value=2` rows for the three
     services), wrapping a maintained tool (`tccplus` / `DocSystem/tccutil`). Document the raw
     SQL as a fallback but prefer the tool since the schema drifts across macOS versions.
- `scripts/reset-permissions.sh` — `tccutil reset {Microphone,Accessibility,ListenEvent} <bundleid>`
  for a clean-slate test run.
- **Use the stable self-signed identity** ([§9](#9-build-sign-run)) so one grant survives all
  rebuilds within a test session.

The harness must **verify** grants after granting (don't assume): the app exposes
`murmurctl permissions` returning the three booleans (from the same detect APIs in
[§8](#86-permissions)); the harness asserts all true before running functional tests.

### 10.2 Control interface — the automation seam
The app runs a **local control server** on a Unix domain socket at
`~/Library/Application Support/Murmur/control.sock` (only present when the app is running). A CLI
target **`murmurctl`** (built from the same package, swift-argument-parser) sends line-delimited
JSON requests and prints JSON responses. This lets the harness drive the app with **no synthetic
keyboard events and no live microphone**.

Commands (all also usable by a human for debugging):

| Command | Effect | Returns |
|---|---|---|
| `murmurctl status` | current state machine state, active session id | `{state, sessionId}` |
| `murmurctl permissions` | TCC status | `{microphone, inputMonitoring, accessibility}` |
| `murmurctl start` | begin recording from the **current audio source** | `{sessionId}` |
| `murmurctl stop` | stop recording, run transcription, insert | `{sessionId, transcript}` |
| `murmurctl inject <wav>` | **one-shot**: run the full record→transcribe→insert path using `<wav>` as the audio source instead of the mic | `{sessionId, transcript}` |
| `murmurctl transcribe <wav>` | **headless**: transcribe a file and return text, no HUD/insert/session | `{transcript}` |
| `murmurctl retry <id>` | re-transcribe a saved session from its audio | `{transcript}` |
| `murmurctl last` | last session's meta.json | `{...meta}` |
| `murmurctl sessions` | list recent sessions + states | `[{id,state,...}]` |

`inject` is the workhorse for end-to-end tests: it swaps a `FileAudioSource` (which replays the
WAV through the exact same `AudioSource` → `Recorder` → transcription path the mic uses) so the
output is **deterministic** for a fixed input WAV. `transcribe` is the fast path for unit-testing
the model with zero permissions.

> A `murmur transcribe <wav>` **headless subcommand of the app binary itself** (not via socket)
> must also exist, so the transcription backend can be tested before any GUI/permission work.

### 10.3 Test audio fixtures
Commit small fixtures under `Tests/Fixtures/` (all 16 kHz mono WAV, a few seconds each):
- `hello_world.wav` → expected ≈ `"hello world"` (short sanity).
- `the_quick_brown_fox.wav` → a known pangram-ish sentence.
- `numbers.wav` → e.g. `"testing one two three"`.
- `silence.wav` → expected empty / whitespace transcript.
- `long_60s.wav` → a ~60s clip to exercise chunking + timing.

Generate them **without a human voice** so tests are reproducible and CI-portable:
- Preferred: macOS `say` piped to the right format —
  `say "hello world" -o /tmp/h.aiff && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/h.aiff hello_world.wav`.
  `say` output is clean TTS that Parakeet transcribes reliably, giving stable expected strings.
- A `scripts/make-fixtures.sh` regenerates them so they're not opaque binaries.

Assertions use **normalized comparison** (lowercase, strip punctuation, collapse whitespace) and,
where exactness is unrealistic, a **word-error-rate threshold** (e.g. WER ≤ 0.1) rather than
string equality — TTS + ASR isn't bit-exact. `silence.wav` asserts empty output.

### 10.4 Observability
- **Structured JSON logs** to `~/Library/Application Support/Murmur/logs/murmur.log`, one object
  per line: `{ts, level, event, sessionId, state, msg, ...}`. Every state transition, permission
  check, transcription start/end (+duration), insertion, error, and tap re-enable is logged. The
  harness tails this to assert on behavior and to debug failures without a screen.
- `murmurctl status`/`last`/`sessions` expose state without log parsing.
- Exit codes: `murmurctl` returns non-zero on error with a JSON `{error}` on stderr.

### 10.5 Test layers (the agent's build-to-reliable loop)
1. **Backend unit tests** (no permissions, XCTest + `murmur transcribe`): each fixture →
   normalized/WER assertion. Proves the model + audio decoding work. Run first, iterate here
   until green.
2. **Persistence/retry unit tests:** create a session, kill transcription mid-way (inject a
   failing `TranscriptionEngine` stub), assert audio survives, assert launch-recovery re-runs it,
   assert `retry` produces the transcript. Simulate crash by asserting a truncated `audio.caf`
   still decodes.
3. **Hotkey unit test:** feed synthetic `CGEvent`s (or unit-test the `Trigger` matching logic in
   isolation) for Fn+Space and the dev override; assert start/stop fire. (Full CGEventTap needs
   Input Monitoring; keep the *matching logic* pure and unit-testable, separate from the tap.)
4. **End-to-end via control socket** (needs the three permissions granted per
   [§10.1](#101-permission-automation)):
   - Launch `Murmur.app` with `MURMUR_TRIGGER=ropt-space`.
   - `murmurctl permissions` → assert all true.
   - Open **TextEdit** with a blank document (`open -e` / AppleScript), focus it.
   - `murmurctl inject Tests/Fixtures/hello_world.wav`.
   - Read TextEdit's content back via **AppleScript** (`tell app "TextEdit" to get text of document 1`)
     or the Accessibility API, and assert it contains the expected words.
   - This proves the *entire* real path: audio source → recorder → transcription → paste →
     landed in a real third-party app. No mic, no human, fully deterministic.
5. **Clipboard-restore test:** put a sentinel on the clipboard, run an `inject`, assert the
   sentinel is restored after insertion.
6. **Real-hotkey smoke (optional, best-effort):** post a synthetic `⌥`+`Space` via `CGEvent` and
   assert recording starts — validates the tap itself end-to-end. May be flaky in headless CI;
   keep it non-blocking.

### 10.6 One-command harness & acceptance
- `scripts/test.sh` runs: build → bundle → sign → grant-permissions → unit tests → launch app →
  e2e socket tests → teardown (`reset-permissions`, quit). Exits non-zero on any failure and
  prints a summary. **This is the loop the agent runs repeatedly until green.**
- The app is "reliable" (done) when, on the target Mac:
  - [ ] All backend + persistence + hotkey-logic unit tests pass.
  - [ ] `scripts/test.sh` e2e passes **10 consecutive runs** (guards against flaky tap/paste/
        timing races).
  - [ ] Launch-recovery test: force-kill the app mid-transcription (send SIGKILL between
        `start` and transcription completion), relaunch, assert the session auto-completes from
        saved audio.
  - [ ] `numbers.wav`, `hello_world.wav`, `the_quick_brown_fox.wav` land in TextEdit within WER
        ≤ 0.1; `silence.wav` inserts nothing.
  - [ ] No `error`-level log lines across a full `test.sh` run except those the failure tests
        intentionally cause.

The agent should treat §10.6 as its definition of done and keep iterating (fixing bugs, adding
missing seams) until every box is checked across repeated runs.

---

## 11. Project layout
```
Murmur/
  Package.swift
  Sources/
    Murmur/                 # the app
      MurmurApp.swift       # @main, MenuBarExtra, wires everything
      AppModel.swift        # @MainActor state machine
      Hotkey/HotkeyEngine.swift, Trigger.swift
      Audio/AudioSource.swift, MicAudioSource.swift, FileAudioSource.swift, Recorder.swift
      Transcribe/TranscriptionEngine.swift, ModelManager.swift, TranscriptProcessor.swift
      Session/SessionStore.swift, Session.swift
      Insert/TextInserter.swift
      UI/MenuBar.swift, TranscriptHUD.swift, PermissionsWindow.swift
      Control/ControlServer.swift   # unix socket
      Support/Log.swift, Config.swift, Permissions.swift
    murmurctl/              # CLI client (swift-argument-parser)
      main.swift
  Tests/
    MurmurTests/            # unit tests (backend, persistence, trigger logic)
    Fixtures/*.wav
  scripts/
    bundle.sh make-cert.sh grant-permissions.sh reset-permissions.sh
    run.sh test.sh make-fixtures.sh
  assets/
    Murmur.entitlements  Info.plist  murmur.pppc.mobileconfig
  README.md  SPEC.md
```

---

## 12. Milestones
1. **Backend proves out:** `murmur transcribe <wav>` works on fixtures (FluidAudio download +
   load + transcribe). Unit tests green. *No GUI, no permissions.*
2. **Record loop headless:** `AudioSource`/`Recorder`/`SessionStore` + `murmurctl inject` — full
   record→transcribe→session on disk, crash-safe CAF, retry + launch-recovery. Persistence tests
   green.
3. **Insertion + control socket:** `TextInserter` paste, `ControlServer`, e2e TextEdit test green.
4. **Hotkey + menu bar + HUD:** `CGEventTap` Fn+Space (dev override), menu bar status, live
   transcript pill. Permissions window.
5. **Harden to acceptance:** run `scripts/test.sh` ×10, fix flakiness, meet every §10.6 box.

Ship milestone by milestone; each is independently testable.

---

## 13. Open guesses (flagged for the human to redirect in seconds)
- **Name "Murmur"** — pure guess; rename freely.
- **Default trigger mode = toggle** (matches your FluidVoice `Fn` toggle setup). Say the word to
  default to hold-to-talk.
- **Auto-retry = 3 attempts, keep audio forever.** Matches "keep recordings" in your setup.
- **Two-pass streaming+final** vs. simpler "partials for HUD, full re-transcribe on stop": spec
  allows the fallback; implementer picks whichever is reliable first.
- **Dev override = Right-Option+Space.** Change if it clashes with something you run.

---

## 14. Attribution & license
- App: MIT (or your preference).
- Bundles/downloads **NVIDIA Parakeet** (`parakeet-tdt-0.6b-v2` / `-v3`), **CC-BY-4.0** — credit
  NVIDIA and link the model card in README + About.
- Uses **FluidAudio** (Apache-2.0) — credit in README.
- Design owes a large debt to **FluidVoice** (GPLv3) and **MacParakeet**; credit both.

---

These are working reference snippets, not final code — adapt naming/error handling to fit the
modules in [§11](#11-project-layout).

## Appendix A — reference `HotkeyEngine` (CGEventTap)
Session-level `.defaultTap`; bare C callback with `self` via refcon; `flagsChanged` Fn-edge
tracking; toggle vs hold; **mandatory `.tapDisabledByTimeout` re-enable**; swallow the trigger by
returning `nil`.

```swift
import Cocoa
import CoreGraphics

final class HotkeyEngine {
    var trigger: Trigger = .fnSpace
    var onStart: () -> Void = {}
    var onStop:  () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnIsDown = false
    private var isRecording = false
    private var fnDownAt: CFAbsoluteTime = 0
    private let tapThreshold: CFTimeInterval = 0.30   // tap vs hold cutoff

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyEngine>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { Log.warn("tap creation failed — Input Monitoring?"); return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let fnNow = flags.contains(.maskSecondaryFn)
        if type == .flagsChanged {
            let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if kc == 0x3F {                               // kVK_Function
                if fnNow && !fnIsDown { fnDown() }
                else if !fnNow && fnIsDown { fnUp() }
                fnIsDown = fnNow
            }
            if trigger.keyCode == nil { return nil }      // modifier-alone trigger: swallow
        }
        if type == .keyDown, let need = trigger.keyCode {
            let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let fnOK  = trigger.usesFn ? fnNow : true
            let modOK = flags.isSuperset(of: CGEventFlags(rawValue: trigger.modifierFlags))
            if kc == need && fnOK && modOK { fire(); return nil }   // swallow the trigger
        }
        return Unmanaged.passUnretained(event)
    }

    private func fnDown() { fnDownAt = CFAbsoluteTimeGetCurrent()
        if trigger.keyCode == nil && trigger.mode == .holdToTalk { begin() } }
    private func fnUp() {
        guard trigger.keyCode == nil else { return }
        if trigger.mode == .holdToTalk { end() }
        else if CFAbsoluteTimeGetCurrent() - fnDownAt < tapThreshold { toggle() }
    }
    private func fire() { trigger.mode == .holdToTalk ? (isRecording ? end() : begin()) : toggle() }
    private func begin()  { guard !isRecording else { return }; isRecording = true;  onStart() }
    private func end()    { guard isRecording  else { return }; isRecording = false; onStop() }
    private func toggle() { isRecording ? end() : begin() }
}
```
> Keep `Trigger` matching pure and unit-testable ([§10.5](#105-test-layers-the-agents-build-to-reliable-loop) layer 3):
> factor the "does this event match the trigger" decision into a function you can call with
> synthetic inputs, separate from the live tap.

## Appendix B — reference `Recorder` (crash-safe audio)
`AVAudioEngine` input tap at **hardware** format → `AVAudioConverter` → 16 kHz mono Int16 →
append to a streaming `AVAudioFile` CAF each buffer → on stop, transcode to WAV atomically.

```swift
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                 sampleRate: 16_000, channels: 1, interleaved: true)!

func start(to cafURL: URL) throws {
    let input = engine.inputNode
    let hw = input.outputFormat(forBus: 0)            // MUST use hardware format for the tap
    converter = AVAudioConverter(from: hw, to: targetFormat)
    cafFile = try AVAudioFile(forWriting: cafURL, settings: targetFormat.settings,
                              commonFormat: .pcmFormatInt16, interleaved: true)
    input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
        self?.process(buf)                            // convert, write(from:) to CAF, feed streamer
    }
    engine.prepare(); try engine.start()
}
// process(): AVAudioConverter.convert → try? cafFile.write(from: out)  (appends + flushes)

let wavSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
]
// finalize: write WAV to a temp path, FileHandle.synchronize() (fsync), then
// FileManager.replaceItemAt(dest, withItemAt: tmp)  — atomic swap, never a partial file.
```
`FileAudioSource` (test injection) replays a WAV's frames through the **same** `process()` path so
injected and mic audio are indistinguishable downstream.

## Appendix C — reference `TextInserter`
Paste (default): snapshot all `NSPasteboard` items → set our string → post `Cmd`+`V` `CGEvent`s →
restore the snapshot after 0.15s (sync restore races the paste). Type (fallback):
`CGEventKeyboardSetUnicodeString` in ~20-char chunks with `usleep`. Both gate on
`AXIsProcessTrustedWithOptions`.

```swift
func insertViaPaste(_ text: String) {
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
        let c = NSPasteboardItem()
        for t in item.types { if let d = item.data(forType: t) { c.setData(d, forType: t) } }
        return c
    } ?? []
    pb.clearContents(); pb.setString(text, forType: .string)
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)   // 'v'
    let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cgAnnotatedSessionEventTap); up?.post(tap: .cgAnnotatedSessionEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        pb.clearContents(); pb.writeObjects(saved)
    }
}
```
