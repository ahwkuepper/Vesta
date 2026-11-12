# Vesta Home beta validation

Status: **candidate preparation; public installer release is not approved yet**.
Updated November 11, 2026. Keep pending checks visible in a public source preview.
Do not describe a local build as CI-attested or a simulated test as hardware-tested.

## Recorded baseline

The personal 0.1.1 installer passed Apple signing, notarization, stapling and
Gatekeeper assessment. It contains arm64 and x86_64; the Intel executable ran the
sample snapshot mode under Rosetta. That installer was built from a private working
tree and is not the public beta artifact.

Its baseline tests passed: 130 tests in the Liquid Glass build, 130 in the classic
build, and 19 standalone Nest tests. This record does not establish fresh-install
behavior or live device command compatibility for the public candidate.

## Candidate checks

Results from the publication-preparation pass are recorded below when completed.
The source and automated checks can run without accessing a home or Keychain.

- Publication scanner: passed for the candidate text and 22 reviewed binary assets.
  Screenshots use sample data; EXIF contains dimensions only. Certificate fixtures
  contain public keys with synthetic names. Five scanner regression tests passed.
- Clean snapshot: created as a new root commit without private ancestry.
  Pinned Xcode 17C529: 130 tests passed in each UI variant; 19 Nest tests passed.
  Universal optimized build succeeded. The unsigned hash is recorded in
  `release/home-v0.2.0.txt`. A second clean canonical build produced the same hash.
  Both slices ran sample snapshots (Intel under Rosetta); the setup UI was visually
  checked. This does not replace a native Intel or fresh-user hardware check.
- Public CI: both push and PR runs passed for source snapshot `2a805c0`.
  [Run evidence](https://github.com/ahwkuepper/Vesta/actions/runs/43099477644).
  Tagged-build attestation remains pending promotion and a public release tag.
  The runner image documents the required Xcode. Current main protection requires
  the `test` CI job; it does not require a human or code-owner approval. A maintainer
  must review the candidate; CODEOWNERS alone does not provide that enforcement.
- Final public DMG signature, Gatekeeper, contents and checksum: pending.
- Nest consent-site policy: owner-approved [PR #1](https://github.com/ahwkuepper/vesta-nest-site/pull/1)
  merged as `161b4644`. Pages deployment succeeded; both live HTML pages were
  fetched and matched the reviewed files exactly on November 11, 2026.

## Required human/hardware check before an installer release

Use a separate Mac or a new macOS user with no saved Vesta credentials. Record the
candidate version, macOS version, processor family, device models/firmware and
pass/fail result without home identifiers. These checks are still **pending**:

1. Install from the downloaded/quarantined final DMG. Verify launch, placement and
   scrolling on a small screen. Check keyboard navigation and VoiceOver labels.
2. Allow Local Network and Keychain prompts. Also deny each once and confirm the
   app provides recovery without a crash or silently losing saved configuration.
3. Pair Hue; read and intentionally toggle one safe lamp, dim it, recall a scene,
   and verify the result in the vendor app. Restore its original state.
4. Discover a legacy and an authenticated Kasa device. Sign in; read and change one
   safe lamp, restore it, and inspect schedules. If editing a schedule, use a
   disposable disabled rule and confirm removal; leave household schedules intact.
5. Configure a new personal Nest client/project and authorize. Compare readings,
   relaunch and verify saved authorization. Test an owner-approved small setpoint
   adjustment and restore it. Exercise connection failure and reconnect; controls
   must remain disabled while readings are stale. Do not test with active HVAC
   conditions that make a change inappropriate.
6. Classify an appliance as Device; confirm room/all-light actions exclude it.
   Export/import a layout on another Mac and confirm credentials remain separate.
7. Test sleep/wake, loss/restoration of Wi-Fi and revoked Nest access. Verify clear
   errors and no duplicate writes after an ambiguous failure.
8. Cover the oldest supported macOS and native Intel hardware, or explicitly
   narrow the beta's tested-platform claim. Rosetta is not native Intel hardware.

Do not include room names, addresses, device IDs, screenshots of credentials or
returned OAuth URLs in a public test report.
