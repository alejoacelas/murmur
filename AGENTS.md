---
agent_context:
  version: 1
  groups:
  - tools
  visibility: public
---
<!-- agent-context:begin sha256=cb545175271c3a7242acaa4371e2a433d4fe8566eab054e57071cef6a99bde12 -->
<!-- shared group: tools -->
# Dev Workspace

- This workspace holds software the user relies on frequently. Build it to last, not as throwaway experiments.
- Group related projects under an ordinary shared-function folder whose README indexes them; do not also use that folder as a project repo.
- Keep each project in its own Git repo with its own GitHub remote, including nested projects.
- Commit project work inside its project repo; keep shared workspace config in dotfiles.
- Push after committing.
- Keep changes small.

## Publishing a project

- Create the GitHub remote if it doesn't exist.
- Use a short, clean repo name.
- Make the repo public unless the global privacy rules require a private repo.

## READMEs

- Put real effort into the README.
- Keep it short — write it like a WhatsApp or Slack message, straight to the point.
- If it can be said in one sentence, don't use two.
- When the user's prompt has its own wording and style, preserve that voice; just make it shorter and tighter.
- Write in the user's own first-person voice — a short, honest personal note, not marketing copy.

## Local macOS apps

- Sign apps that need Accessibility, Screen Recording, microphone, camera or similar grants with a stable local identity. Ad-hoc signatures change identity on every build, leaving enabled privacy toggles that the rebuilt app cannot use.
- Make the build fail when its expected signing identity is missing. Do not silently fall back to ad-hoc signing.

## Markdown

- Use [Peter Hartree's Roughdraft fork](https://github.com/peterhartree/roughdraft) as the default Markdown review tool.
- Open files with `roughdraft open "/absolute/path/to/file.md"`.
- After the user reviews or closes a document, reread the file for CriticMarkup feedback.
<!-- agent-context:end -->

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
