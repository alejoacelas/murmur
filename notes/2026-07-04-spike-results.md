# M0 spike results (SPEC.md §0)

Run on the target Mac: macOS 26.3.1 (Darwin 25.3.0), Apple Silicon, Swift 6.3.2, active GUI session. Spike sources in `spikes/` (throwaway SwiftPM package pinning FluidAudio `exact: "0.15.4"`).

## Environment inherited from the bootstrap session

- **TCC grants already in place and verified live**: `{"microphone":true,"inputMonitoring":true,"accessibility":true}` for bundle `com.alejoacelas.Murmur` at `build/Murmur.app`, signed with the self-signed "Murmur Dev" identity (keychain `~/Library/Keychains/murmur-dev.keychain-db`, pass `murmur-dev`). Verified by re-running the committed primer bundle.
- **Model cache warm**: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` (443 MB) survives from the earlier session.
- The old (v1, pre-red-team) partial implementation is backed up at the session scratchpad `pre-pull-backup/` — its `ModelManager`/`TranscriptionEngine` were the ground truth for the 0.15.4 API before the spikes re-verified it.

## Results

| Spike | Verdict | Detail |
|---|---|---|
| S1 API exists | PASS @0.15.4 | `AsrManager` (actor), `AsrModels.downloadAndLoad(to:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:)`, `SlidingWindowAsrManager` (actor), `ASRConfig` + `.default`, `AudioConverter.resampleAudioFile(_:)/(path:)`, `AsrModelVersion.v2/.v3/.tdtCtc110m/.tdtJa`. |
| S2 batch e2e | PASS | hello_world → "Hello world." · fox → exact · numbers → **"Testing 123."** (numerals!) · silence → **empty** (model-level) · long_60s → full text, minor punctuation drift only. ~100–250 ms per clip after load. |
| S3 signature | PASS | `transcribe(_ samples: [Float] | _ url: URL | _ buffer: AVAudioPCMBuffer, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult`. **No `source:`** (fork-only, as REDTEAM predicted). Fresh state per call: `TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)`. `ASRResult` = `{text, confidence, duration, processingTime, tokenTimings, …}`. |
| S4 cache | PASS | Second load from default cache: **484 ms**, no network. `to:` override must point at the **version-specific dir** (`<root>/parakeet-tdt-0.6b-v2`): `repoPath(from:)` = `dir.deletingLastPathComponent() + repo.folderName`. New path ⇒ one-time ~50 s CoreML/ANE compile, then fast. |
| S5 streaming | PASS | External feed: `startStreaming(source:)` (source is a label; audio comes from `streamAudio(buffer)`), partials via `transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>` (`text`, `isConfirmed`, `confidence`), `finish() → String`. 3 updates over the 60 s clip with `.default` config (window-sized cadence — sparse; tune `SlidingWindowAsrConfig` for the HUD in M4). Streaming final ≠ batch final ("no clue. cleanup" glitch) → batch stays the only inserted text. **`loadModels(_ models: AsrModels)` shares one loaded model set between batch + streaming managers.** |
| S6/S7 Fn | SKIPPED | Needs a human pressing keys; Wispr Flow owns Fn on this Mac. Per §4.1/§13 fallback: **Ctrl+Space ships as production default**; `fn-space` stays a selectable, unverified preset. |
| S8 open env | **FLIPPED** | `MURMUR_TRIGGER=via-open open -nW EnvTest.app` → the app **saw the variable** on macOS 26.3. Spec assumed the opposite. Tests still launch by exec (portable; and exec verified too). |
| S9 AppleScript TCC | SKIPPED | Moot — v2 never uses AppleScript (InsertionProbe instead), and the probe itself would pop the Automation prompt while the user is away. |
| S10 PPPC | SKIPPED | Unmanaged Mac, no unattended sudo. Moot — grants done manually once and verified. |
| S11 DR stability | PASS | `designated => identifier "com.alejoacelas.Murmur" and certificate root = H"dc66497239cdcc4947e53796887f94b7b8a551ac"` — byte-identical across rebuild+resign. Note **capital-M identifier is embedded in the DR**, locking the bundle-id decision. |
| S12 CAF kill | PASS | recorder-probe SIGKILLed at ~8.6 s of audio; `afinfo` reads the partial CAF (8.6 s, Float32/16 kHz), `afconvert` → WAV cleanly. |
| S13 GUI session | PASS | `gui/501` Aqua session up; `kCGSSessionSecureInputPID` absent (Secure Input off). |

## Spec corrections applied

1. §2: pin `exact: "0.15.4"`; bundle id fixed as `com.alejoacelas.Murmur` (capital M) with rationale.
2. §4.1: Ctrl+Space is the testing **and** production default; fn-space demoted to unverified preset.
3. §8.1: backend contract rewritten to the real 0.15.4 signature (decoderState inout, no source:), plus shared-`AsrModels` streaming note.
4. §0: results table embedded; REDTEAM.md gained a "Spike outcomes" section.

## Implementation notes carried forward

- `numbers.wav` expected transcript is `testing 123` after normalization (Parakeet emits numerals). Fixed in `Tests/Fixtures/expected.json`.
- FluidAudio's `AudioSource` **enum** name-collides with MurmurKit's `AudioSource` protocol — only `FluidAudioBackend.swift` imports FluidAudio, qualify there.
- Model load: first-ever ~316 s (download+compile), warm ~0.4–0.5 s, new-path ~50 s. `murmurctl wait-ready` timeouts should assume ≤60 s warm-ish, not ≤5 s.
- Both FluidAudio managers are **actors**; all calls `await`.
