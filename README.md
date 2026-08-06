<!--ai-->
# Murmur
<!--/ai-->

<!--ai-->
A minimal, local dictation app for macOS — my open alternative to Wispr Flow, in the spirit of
[FluidVoice](https://github.com/altic-dev/FluidVoice). Press `Fn`+`Space`, talk, and the
transcript lands at my cursor. Everything runs on-device with NVIDIA Parakeet — no cloud, no
account, and no LLM "cleanup" by default. Just my words.
<!--/ai-->

<!--ai-->
It keeps every recording on disk in a crash-safe format, so if a transcription ever fails I can
retry it from the saved audio. A little pill near the cursor shows the transcript live as I speak.
<!--/ai-->

<!--ai-->
**This repo is the spec, not the app yet.** [SPEC.md](SPEC.md) (v2) is a full, build-ready plan —
written so a coding agent can implement it and test it to reliability on its own, with no manual
testing from me. It was red-teamed by GPT-5.4-pro; [REDTEAM.md](REDTEAM.md) records every critique
and whether I took it. If you're that agent, start with [AGENTS.md](AGENTS.md), then do the
Milestone-0 verification spikes in SPEC §0 before writing app code.
<!--/ai-->

<!--ai-->
Stack: pure Swift, [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet on the
Apple Neural Engine, no Python). Apple Silicon only.
<!--/ai-->
