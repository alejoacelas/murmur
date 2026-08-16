# Murmur

A minimal, local dictation app for macOS — my open alternative to Wispr Flow, in the spirit of [FluidVoice](https://github.com/altic-dev/FluidVoice). Press `Ctrl`+`Space`, talk, press it again, and the transcript lands at your cursor. Everything runs on-device with NVIDIA Parakeet — no cloud, no account, and no LLM "cleanup" by default. Just your words.

Every recording is written continuously to a crash-safe CAF file, so a failed (or crashed) transcription retries from the saved audio — including a crash mid-recording. A little pill near the cursor shows the live transcript while you speak; the inserted text always comes from a full batch pass over the saved audio.

Built from [SPEC.md](SPEC.md) (v2, red-teamed — see [REDTEAM.md](REDTEAM.md)) by a coding agent, and tested by that agent end-to-end with zero manual testing: see [§ Testing](#testing).

Stack: pure Swift 6, [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.4 (Parakeet on the Apple Neural Engine, no Python). macOS 14+, Apple Silicon only.

## Build & install

```sh
swift build                                    # library + executables
scripts/make-cert.sh                           # one-time: stable self-signed identity "Murmur Dev"
scripts/bundle.sh .build/debug/Murmur .build/debug/murmurctl   # -> build/Murmur.app (signed)
build/Murmur.app/Contents/MacOS/Murmur &       # or: open build/Murmur.app
```

First run on a fresh machine downloads the Parakeet model (~440 MB) into `~/Library/Application Support/FluidAudio/Models/`, and the first model load per binary pays a one-time CoreML/ANE compile (up to a few minutes); after that it warms in ~0.5 s.

### Permissions (one-time, human)

Murmur needs three TCC grants, requested per feature (the app runs without any of them, minus that feature): **Microphone** (recording), **Input Monitoring** (the global hotkey tap), **Accessibility** (pasting at the cursor). The menu bar item → *Permissions…* shows live status with Settings deep links. Grants stick across rebuilds because the bundle id (`com.alejoacelas.Murmur`) and the self-signed cert keep the designated requirement stable — don't recreate the cert casually.

## Use

- `Ctrl`+`Space` — start recording (pill appears near the cursor with live partials); `Ctrl`+`Space` again — stop, transcribe, paste at the cursor. Toggle only, no hold-to-talk.
- Menu bar mic icon — state, last transcript, manual retry of a failed session, permissions, quit.
- Silence in, nothing out: recordings below the RMS gate insert nothing (Parakeet hallucinates on silence).
- Clipboard is snapshotted and restored (best-effort) after a paste.
- Config: `~/Library/Application Support/Murmur/config.json` — `trigger` (`ctrl-space` | `fn-space`), `insertion` (`paste` | `type`), `preserveClipboard`, `retention` (`keep` | `deleteOnSuccess`). `fn-space` is an unverified preset: Wispr Flow owned `Fn` on the dev machine, so the Fn spikes never ran (SPEC §0 S6/S7).
- Everything is scriptable without touching the mic or keyboard: `murmurctl health | inject <wav> | transcribe <wav> | sessions | retry <id> | quit …` over a unix control socket.

Recordings + transcripts live under `~/Library/Application Support/Murmur/recordings/<id>/` and are kept by default — audio is sacred; a transcript can always be regenerated (`murmurctl retry`).

If the app crashes (even mid-recording), relaunch it: recovery finalizes the partial audio and auto-completes the session — the paste goes to whatever you have focused at relaunch.

## Testing

The whole loop is autonomous (SPEC §10): `scripts/test.sh [N]` runs preflight → build → bundle+sign → unit tests (backend against the real model, persistence/retry against mocks, pure hotkey matcher) → crash-recovery e2e (SIGKILL mid-recording and mid-transcription, relaunch, auto-complete from saved audio) → N× the socket-driven e2e: fixtures injected as the audio source, pasted into `InsertionProbe.app` (a focused NSTextView that mirrors itself to a file — no AppleScript, no TextEdit), plus a clipboard-restore check and a synthetic-Ctrl+Space smoke through the real event tap.

Coverage honesty (SPEC §10.6): the automated loop proves the file-injection path end-to-end; the **live microphone path** is covered by a real-mic hotkey smoke + unit tests, not fixture assertions (no virtual audio device installed); **HUD visuals** are asserted via control-API state (`murmurctl hud`), not screenshots; **Fn+Space** is unverified. Details in `notes/`.

## Attribution & license

- App: [MIT](LICENSE).
- Transcription: [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) `parakeet-tdt-0.6b-v2` (CC-BY-4.0) via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).
- Design owes [FluidVoice](https://github.com/altic-dev/FluidVoice) (GPLv3) and [MacParakeet](https://github.com/moona3k/macparakeet).
