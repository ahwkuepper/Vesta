# Security

Vesta controls devices in a home. A malicious contribution or compromised release
could reach those devices and the credentials available to the application.
This document distinguishes the original Hue app from Vesta Home and its providers.

## Scope and boundaries

| Component | Network and authentication | Important limits |
|---|---|---|
| Hue / original Vesta | Local bridge HTTPS; public-key pin recorded during physical pairing; scoped Keychain application key | Pairing is a trust-on-first-use step. A compromised paired bridge remains trusted. |
| Kasa | LAN discovery and legacy XOR or authenticated KLAP; derived account keys in a separate Keychain service | Legacy XOR offers no device authentication. Similar models can use different firmware protocols. |
| Nest / Home | Google HTTPS OAuth and SDM; system TLS validation; scoped Keychain configuration and refresh token | Cloud integration; Google grant can control devices. User-configured project, no shared public client. |
| Nest CLI | Same Google service and credential store, read-only default transport | Read-only code does not reduce the scope of the OAuth grant. |
| Layout preview | Synthetic in-memory devices | No transports or credential access. |

Home explicitly enables five Nest thermostat commands. Each command is validated
against a fresh authorized device list and current mode/connectivity, then sent
once and read back. A failed response does not automatically replay a command.
The app limits targets to 10–32°C with a 0.5°C minimum heat/cool separation;
provider/device constraints may be stricter. Stale readings disable controls.

The apps have no third-party application dependencies, runtime plugin loader,
developer backend, telemetry, crash upload or automatic updater. Apple frameworks,
the compiler, OS and release tools remain trusted dependencies. The sandbox cannot
express "LAN only": transport validation and source review enforce that intent.
Kasa requires HTTP to numeric local addresses. Nest separately restricts HTTPS
methods/hosts/paths, rejects redirects and bounds response size and request time.

Home's sandbox allows network client/server access (including discovery) and
user-selected file read/write for setup and layout transfer. It has no camera or
microphone entitlement. Entitlements differ from the original Hue app; inspect
`home/entitlements.plist` for the Home build. Browser consent and documentation links
are explicit user actions, not app telemetry.

## Credentials, stored data and diagnostics

Hue, Kasa and Nest have separate Keychain stores. They are source-level boundaries,
not a defense against malicious code running within Home's process. Home can reuse
the companion apps' entries after macOS grants access; deleting a shared entry can
affect those apps. Credentials are excluded from source snapshots and installers.
User-downloaded OAuth JSON and returned URL files need their own protection/deletion.

Kasa device metadata and last-known state, room assignments and preferences persist
locally. Layout exports include room names and identifiers. Do not treat them or
screenshots as safe to publish. The Hue diagnostic report intentionally omits
identifying names and addresses; general screenshots, CLI readings and user-supplied
error attachments are not that diagnostic report. See [Home privacy](home/PRIVACY.md).

## Automated checks and their limits

- `tools/check-boundaries.sh` makes unexpected network APIs, host literals,
  dependencies, dynamic loading and target layering visible. These structural
  checks supplement review; they are not a complete data-flow or sandbox proof.
- `tools/check-no-secrets.sh` scans tracked and nonignored untracked text for
  credential formats and home identifiers. It reports locations without printing
  matches. Binary assets require reviewed SHA-256 entries. Tests exercise untracked
  leaks and redaction. Patterns cannot detect every secret or private fact.
- Test transports exercise malformed input, failed commands and credential errors.
  They do not establish live device compatibility. [Home validation](home/VALIDATION.md)
  records hardware and fresh-install gaps explicitly.

Before publishing, make a source snapshot with no private ancestry. Never push a
private tag: it would expose its parent history. The source scanner does not clear
old commits. `tools/prepare-public-snapshot.sh` creates a local candidate;
`tools/publish.sh` parents published snapshots only on public history.

## Release integrity

Developer ID and notarization credentials remain on the maintainer's Mac, outside
CI. Home uses a pinned Xcode and a fixed build path. Its release workflow checks a
manifest hash and produces GitHub provenance for the unsigned binary. The Home
packager requires a matching attestation bound to the public tag, commit and Home
workflow, with no bypass. The original Hue release script is separate and still
has a manual attestation override; do not use it for Home.

A signature identifies the signer; notarization is not a code audit. Unsigned-build
reproducibility does not itself authenticate a downloaded DMG. Check its checksum,
signature and Gatekeeper result separately. See [Home releasing](home/RELEASING.md).
CODEOWNERS identifies reviewers, but required review/CI must also be configured in
GitHub branch protection. No fork PR should receive signing credentials.

## Reporting

For vulnerabilities, use the repository's private security advisory. Use public
issues only for non-sensitive reports. Do not attach tokens, OAuth client files,
authorization URLs, home identifiers or unredacted device data. Firmware compromise,
physical device access and an already-compromised Mac are outside the app's defenses.
