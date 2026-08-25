## What this changes

<!-- One or two sentences. -->

## How it was verified

<!-- What you measured, not what you expect. Numbers, output, a screenshot.
     "Should work" is not verification. -->

## Constitution check

See [CONSTITUTION.md](../CONSTITUTION.md). Tick what applies, or say why not.

- [ ] Adds no third-party dependency (Article 2)
- [ ] Adds no network destination outside a reviewed transport (Article 1)
- [ ] Loads no code at runtime (Article 3)
- [ ] Handles device input as untrusted — no force unwraps, bounded, timed out (Article 4)
- [ ] Puts no secret in a file, log or diagnostic (Article 5)
- [ ] Adds nothing identifying to the diagnostics report (Article 6)
- [ ] Surfaces any new failure path to the user (Article 7)

**This is a security-relevant change** (transport, credentials, entitlements,
diagnostics): yes / no

## New device support only

- Talks to: <!-- protocol, ports, discovery method -->
- Authenticates the device by: <!-- or "nothing — the protocol has no authentication" -->
- Stores: <!-- credentials, where -->
- Can prove about the device: <!-- be honest; "nothing" is an acceptable answer -->
