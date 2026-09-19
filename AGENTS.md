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

# Murmur maintenance

Read [README.md](README.md) for current behavior and [SPEC.md](SPEC.md) for the design.
The app and verification spikes already exist; use `notes/` and `spikes/` as evidence
rather than restarting the original build sequence. Keep changes within the five
must-have features unless the user expands the scope.

- Verify changes yourself through the control socket, `murmurctl`, audio injection
  and logs. Preserve crash-safe recordings and retry/relaunch recovery.
- Use `Ctrl`+`Space` for tests. `Fn`+`Space` remains unverified (S6/S7); do not claim
  support without testing it. Launch the bundle executable directly when a test
  needs environment variables; `open` does not forward them.
- Keep the stable signing identity. First-time TCC grants require the user's Mac
  permissions; `scripts/prime-permissions.sh` launches the permission primer.
  Do not assume permissions are already available or promise to bypass them.
- For app behavior changes, run `scripts/test.sh`: unit tests, crash recovery and
  fixture insertion into `InsertionProbe.app`, clipboard restoration and hotkey checks.
  Use `scripts/test.sh 10` for acceptance/hardening changes. Report missing prerequisites
  and coverage gaps; fixture injection does not prove live microphone or HUD visuals.

Record substantive maintenance and verification in [REPLICATE.md](REPLICATE.md).
