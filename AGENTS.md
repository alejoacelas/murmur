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
