# Red-team judgments (v1 → v2)

`gpt-5.4-pro` red-teamed [SPEC.md](SPEC.md) v1 with a "will an autonomous agent fail on this?"
lens. I judged each finding against the goal (an agent builds *and* self-tests to reliability) and
against ground truth I could check — notably the **FluidAudio public API, which I verified against
the real package README**: `AsrManager(config:.default)`, `AsrModels.downloadAndLoad(version:.v2/.v3)`,
`transcribe(...)`, `SlidingWindowAsrManager`, `AudioConverter().resampleAudioFile(path:)` all exist.
The one real discrepancy: upstream `transcribe(samples)` takes **no `source:` argument** — v1's
`transcribe(_:source:)` came from FluidVoice's *fork*. Hence spike **S3**.

**Verdict counts:** Accepted 30 · Tempered 3 · Rejected 1. The review was high-quality; I adopted
almost all of it. Below, "→ §" points to where it landed in v2.

## Accepted — folded into v2

### Build / dependencies / API
| Finding | Why valid | → |
|---|---|---|
| Pin FluidAudio `exact:`, not `from:` | Pre-1.0 semver breaks API; an autonomous build must be reproducible | §2 deps |
| Mandatory **API spike before app code** + wrap behind a protocol | Biggest version-fragility risk; a wrong symbol = days lost | §0 S1–S3, §8.1 `TranscriptionBackend` |
| `transcribe(source:)` unverified | Confirmed: upstream has no `source:` (fork-only) | §0 S3, §8.1 |
| Don't build a **dual-mode GUI/CLI binary**; use a shared library + separate execs | Cleaner, avoids app-lifecycle-vs-CLI friction | §2, §11 (`MurmurKit` + `Murmur`/`murmurctl`/`murmur-smoke`) |
| Pin a **stable bundle id** | PPPC/TCC/designated-requirement all key on it | §2 `com.alejoacelas.murmur` |
| **Configurable paths**, temp root per test | Hardcoded `~/Library/...` pollutes state across runs → flakes | §2 `$MURMUR_HOME` |
| Cut scope: preset triggers, toggle-only, English-v2-only | Less surface for a minimal app + an agent | §1, §4.1 |

### Audio pipeline / concurrency / persistence
| Finding | Why valid | → |
|---|---|---|
| Ambiguous pipeline ownership (source vs recorder) | Three incompatible implementations possible | §3, §5.1 canonical Float32; resample in `MicAudioSource` |
| **Tap callback must enqueue only** (no convert/IO/inference) | Not real-time safe → dropped audio, tap disable, deadlock | §3, §5.2 `CaptureWorker` |
| `@MainActor` races; add explicit async boundaries | Stop-while-draining / state-before-finalize races | §3 |
| `stop()` needs completion/EOF semantics | Must know when no more buffers arrive before finalize | §3 `stop() async` |
| Recovery **misses crash-mid-recording** | v1 only scanned recorded/transcribing/failed | §7.3 stale-`recording` + orphan-dir recovery |
| **Split transcription vs insertion failure** | Re-transcribing after a paste failure duplicates output | §7.2 `transcribed`/`insertFailed` |
| Auto-retry **thrashes on permanent failures** | Missing model/corrupt file retries every launch | §7.3 transient/permanent classification + budget |
| Authoritative audio = capture artifact; WAV derived | Crash before WAV exists must still transcribe | §5.3 |
| **Silence → hallucination**; add RMS/VAD gate | ASR invents text on silence; `silence.wav` would flake | §5.4 |
| Missing operational states (cancel, mic busy, no device, model warming, empty) | App would hang/retry wrong thing | §7.2, §8.6, §13 |

### Hotkey
| Finding | Why valid | → |
|---|---|---|
| Match on **latched** modifier state, not the event's flags | Space's own event may not carry the modifier bit | §4.2 |
| **Exact** modifier match, not `isSuperset` | `Cmd+Ctrl+Space` would wrongly fire `Ctrl+Space` | §4.2 |
| **Swallow both keyDown and keyUp** | Stray key-up causes target weirdness | §4.2 |
| `maskAlternate` can't distinguish L/R Option | v1's "Right-Option" was unencodable → switched dev/test hotkey to **Ctrl+Space** | §4.1 |
| Fn+Space is **hardware/settings-fragile**; verify + fallback; never test on Fn | Globe may be bound to input-source/emoji; Secure Input | §0 S6/S7, §4.1 |

### Text insertion
| Finding | Why valid | → |
|---|---|---|
| Target may **not be frontmost** when final text is ready (toggle race) | Pastes into the wrong app | §8.4 focus capture at start + re-check |
| 150 ms restore arbitrary; make best-effort/configurable; consider AX insert | Async paste races the restore | §8.4 |
| Clipboard snapshot restore is **lossy** | File promises/custom providers don't round-trip | §8.4 |
| Probe `.cgAnnotatedSessionEventTap` vs `.cghidEventTap` | Post-tap acceptance is app-sensitive | §8.4 |
| Typing fallback fragile (IME/emoji) → ASCII-ish only | Not a "reliable primary" path | §8.4 |
| **Secure input / password fields unsupported** | Secure Input blocks tap+paste+typing | §1, §8.4 |

### Autonomous testing (the core of the goal)
| Finding | Why valid | → |
|---|---|---|
| **Replace TextEdit+AppleScript with `InsertionProbe.app`** | AppleScript adds a 4th TCC domain (Automation) + focus/first-run flakiness | §10.5 |
| Not truly headless — needs an **active Aqua GUI session** | Taps/posting/panels/focus require it | §0 S13, §10.6 `preflight.sh` |
| **`open` doesn't pass env vars** to the app | `MURMUR_TRIGGER`/`MURMUR_HOME` would be silently ignored | §0 S8, §9 (launch by exec) |
| **Permissions are bootstrap, not per-run**; PPPC only reliable on MDM; TCC.db only on SIP-off | v1 implied a portable conjure-permissions path | §10.1 |
| Self-signed cert gotchas (partition list, ACLs) + verify the **DR**, not "codesign ok" | Grants won't persist otherwise | §0 S11, §9 |
| Expand control API (`wait-ready`, `await-state`, `model status/ensure`, `quit`, fault injection) | Otherwise the harness blind-`sleep`s | §10.2 |
| Commit fixed fixtures; **WER≤0.1 meaningless on short clips** | `say` drifts; 1 error in "hello world" = WER 0.5 | §10.3 exact-match short, WER long |
| Kill-mid-transcription needs **fault injection** to be deterministic | Short files finish before SIGKILL | §10.2 `fault`, §10.6 |
| Recovery test should kill a **real writer**, not truncate synthetically | Truncation ≠ a dying write | §0 S12, §10.4 |
| Loop doesn't prove **mic path / hotkey / HUD** | `inject` bypasses the mic; be honest or add coverage | §6 `murmurctl hud`, §10.5 coverage-honesty, §10.6 |

### Scope
| Finding | → |
|---|---|
| Permissions **gated by feature**, not "useless without all three" | §8.6 |
| Drop v3 multilingual from v1 | §1 |
| HUD not verified by harness → expose via control API | §6 |

## Tempered — valid but overstated, adjusted rather than adopted verbatim
| Finding | My adjustment | → |
|---|---|---|
| "CAF crash-safe / flushes every write" is **false** | True for **power loss**, not for the actual requirement. `AVAudioFile.write` hands bytes to the OS, so written audio **survives a process crash/SIGKILL** (what "retry after failure" needs). I kept CAF as authoritative, stated the guarantee precisely (crash yes, power-loss no), added periodic `fsync`, and require empirical proof via S12 rather than dropping the format. | §5.3, §0 S12 |
| Two warm managers double ANE/memory | Real risk, but the user explicitly wants the live transcript. Kept **batch as authoritative**, demoted streaming to best-effort, prefer a single warm model / short-lived streaming session, with a documented downgrade to "listening…" if S5 is fiddly — rather than cutting streaming outright. | §8.2, §6 |
| `replaceItemAt` isn't crash-durable | Correct; I stopped selling WAV durability and made **WAV a derived cache** with CAF as truth — but kept the atomic-rename for the convenience artifact. | §5.3 |

## Rejected
| Finding | Why not |
|---|---|
| (Implied) drop the live HUD / consider WhisperKit | The live transcript is an explicit user must-have, and Parakeet is non-negotiable, so WhisperKit (not Parakeet) is a non-starter. Kept FluidAudio + the HUD; addressed the underlying risks (streaming fragility, HUD unverifiability) via best-effort framing + control-API observability instead of cutting the feature. |

## What the model got right that I'd underweighted
The **`open`-doesn't-pass-env-vars** gotcha (S8) and the **InsertionProbe-over-AppleScript** redesign
are the two changes most likely to have silently wrecked the autonomous loop; both are now
first-class. The **split of transcription vs insertion state** also closes a real duplicate-output bug.
