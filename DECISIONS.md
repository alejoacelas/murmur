# Murmur decisions

## Core decisions

### Product scope

- [Keep on-device transcription without default model cleanup](#decision-1).

### Recoverable audio

- [Persist recordings continuously and retain retryable session state](#decision-2).
- [Separate insertion failure from transcription failure](#decision-3).

### macOS boundaries

- [Keep stable signing and explicit per-feature permissions](#decision-4).

### Verification

- [Use Ctrl-Space and report the unverified boundaries](#decision-5).

## Details

<a id="decision-1"></a>

### Keep on-device transcription without default model cleanup

The app’s core job is hotkey, speech and insertion. FluidVoice remains the user’s current baseline while Murmur is evaluated; do not describe this checkout as having replaced it or expand beyond the five must-have features without a new request. See [AGENTS.md](AGENTS.md).

<a id="decision-2"></a>

### Persist recordings continuously and retain retryable session state

The saved CAF file is authoritative through crashes and transcription failures. Batch transcription produces inserted text; live partials are display-only. Preserve retries, orphan/relaunch recovery and default audio retention rather than discard the material needed to retranscribe. See [Sources/MurmurKit/Session/Engine.swift](Sources/MurmurKit/Session/Engine.swift).

<a id="decision-3"></a>

### Separate insertion failure from transcription failure

Retry failed insertion using the existing transcript instead of paying the transcription cost again. Preserve silence gating to avoid inserting hallucinated text and best-effort clipboard restoration around paste. See [Sources/MurmurKit/Session/Engine.swift](Sources/MurmurKit/Session/Engine.swift).

<a id="decision-4"></a>

### Keep stable signing and explicit per-feature permissions

Microphone, Input Monitoring and Accessibility grants belong to macOS and may require the user. Do not recreate the signing identity casually or assume enabled toggles authorize a differently signed binary. See [README.md](README.md).

<a id="decision-5"></a>

### Use Ctrl-Space and report the unverified boundaries

Fn-Space remains unverified. Socket-driven fixture tests demonstrate the file-injection path, not real microphone transcript accuracy or HUD appearance; preserve those coverage limits and the acceptance harness for behavior changes. See [notes/2026-07-05-coverage.md](notes/2026-07-05-coverage.md). History inspected: [432a37b](https://github.com/alejoacelas/murmur/commit/432a37b), [cff0b99](https://github.com/alejoacelas/murmur/commit/cff0b99).
