# Security

Lumo controls devices in someone's home from a machine on their network. Its code is
therefore a supply chain into that home. This is what holds today, and what must
change before it accepts device modules from strangers.

## Threat model

| | Threat | Why it matters here |
|---|---|---|
| T1 | A malicious or compromised contribution | Device modules are the obvious vector: plausible code, privileged reach |
| T2 | A compromised dependency | A transitive package runs with the app's full entitlements |
| T3 | A hostile device on the LAN | It can impersonate a bridge, or answer discovery first |
| T4 | Another app on the same Mac | Wants the app keys, which grant control of the home |
| T5 | A stolen or unlocked machine | Keychain items, paired credentials |
| T6 | The user disclosing something by accident | Diagnostics, screenshots, an issue report, the repo itself |

Out of scope: a compromised bridge or bulb firmware, and anyone with physical access
to the light switch.

## What holds today

Verified, not asserted — `tools/check-boundaries.sh` runs these in CI:

- **No third-party dependencies at all.** Apple frameworks only; there is no
  `Package.resolved` because nothing remote is ever resolved. T2 is closed by having
  no supply chain rather than by auditing one.
- **No outbound traffic to anywhere but the paired device.** The only URLs
  constructed anywhere are `https://<address>` where the address came from pairing.
  There is no analytics, no crash reporting, no update check.
- **Network access is confined to one module.** Only `Sources/LumoBridge` may use
  `URLSession` or `Network`; the check fails the build otherwise.
- **No runtime code loading.** No `dlopen`, no plug-in bundles. A loaded bundle would
  inherit the app's sandbox, entitlements and Keychain access.
- **Sandboxed with two entitlements**: `device.bluetooth` and `network.client`. No
  file access, no camera, no microphone, no inbound server.
- **Credentials in the Keychain**, never on disk, `AfterFirstUnlockThisDeviceOnly`,
  and never logged.
- **TLS pinned to the paired bridge.** The certificate's common name must equal the
  bridge ID recorded at pairing, so a device that seizes the bridge's DHCP address
  cannot impersonate it (T3).
- **Device responses are treated as untrusted input.** No `try!` or `as!` in
  `Sources`; decoding is total and a malformed payload degrades rather than crashes.
- **Diagnostics disclose nothing identifying.** No light, room or scene names; the
  bridge ID and app key appear only as fingerprints (T6).

## What must change before third-party device modules

Each item below closes a hole that opens the moment someone else's module ships.

1. **A single egress choke point.** `network.client` permits *any* outbound
   connection; the sandbox cannot express "LAN only". Introduce
   `LocalNetworkSession`, the only way any module may make a request, which refuses
   destinations outside RFC1918/link-local. The boundary check then enforces that no
   module constructs its own session. Today this is convention; it needs to be code.
2. **Declared capabilities per module.** A module states what it needs — LAN TCP,
   BLE, mDNS — and the host refuses to initialise one that asks for more than its
   declaration. Makes over-reach visible in a diff.
3. **Per-module credential scoping.** Keychain items are namespaced
   `dev.lumo.Lumo.<module>` and a module is handed only its own. A Kasa module must
   not be able to read the Hue app key.
4. **A device-authentication statement per module.** Hue pins a certificate. Kasa's
   legacy local protocol has none: a UDP broadcast on port 9999 enumerates devices
   with no credential, and the plugs return the home's latitude and longitude,
   `deviceId`, `oemId` and MAC to anyone on the LAN. Every module must document what
   it can and cannot prove about the device it talks to, the UI must not imply more,
   and **fields like location must never reach a log or a diagnostics report**.
5. **Repository controls.** Protected `main`, required review, `CODEOWNERS` over
   `tools/`, `Package.swift`, entitlements and any transport; signed commits; no
   `pull_request_target`; no CI secrets exposed to fork PRs; secret scanning.
   Published snapshots reach `main` only through a CI-gated pull request from
   `staging` — see `tools/publish.sh`.
6. **A review checklist for new modules**, covering: no new dependencies, no new
   entitlements, all I/O through the choke point, no telemetry, total decoding,
   bounded response sizes and timeouts, credentials scoped, and a stated
   authentication model.
7. **Release integrity.** Signed and notarised builds, published checksums, and
   instructions to rebuild from source and compare.

## Reporting

Open a GitHub issue for anything non-sensitive. For a vulnerability, use GitHub's
private security advisory on the repository rather than a public issue.
