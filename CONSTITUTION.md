# Lumo's constitution

Lumo controls lights in people's homes and runs on their personal machines. It is
open source, so its contributors are strangers.

Every article names the mechanism that enforces it. Where an article is unenforced,
it says so; those gaps are where to spend effort next.

---

## Article 1 — Nothing leaves the machine

Lumo talks to devices on the local network and to nothing else. No telemetry, crash
reporting, update checks, analytics, or remote configuration.

*Enforced by:* `tools/check-boundaries.sh` fails the build if a hard-coded host
appears in `Sources/`, or if network APIs are used outside a reviewed transport
module. Runs in CI on every push and pull request.

*Gap:* the `com.apple.security.network.client` entitlement permits any outbound
connection; macOS has no LAN-only entitlement. The check is structural, not a kernel
guarantee. A choke point rejecting non-private address ranges would close this and is
the highest-value outstanding security work.

## Article 2 — No third-party dependencies

Apple frameworks only. A dependency runs with the app's entitlements, sandbox and
Keychain access.

*Enforced by:* `check-boundaries.sh` fails if `Package.swift` declares a remote
package or if `Package.resolved` exists.

Where a dependency becomes unavoidable, vendor it into the tree so it is reviewed
like any other code.

## Article 3 — Device modules are compiled in, never loaded

A plug-in bundle inherits the host app's entitlements, sandbox and Keychain, so there
is no boundary between the app and a plug-in it loads. Device support is added as a
target in this repository, through review.

*Enforced by:* `check-boundaries.sh` fails on `dlopen`, `Bundle(path:)` and
`NSClassFromString`.

## Article 4 — Device input is untrusted

Anything arriving from the network is attacker-controlled, including from devices the
user owns. Decoding must be total: no force unwraps, no unbounded reads, a timeout on
everything.

*Enforced by:* `check-boundaries.sh` fails on `try!` and `as!` in `Sources/`.
Contract tests decode recorded payloads, including malformed ones.

*Gap:* response size limits are not enforced.

## Article 5 — Credentials are scoped and never on disk

Secrets live in the Keychain — never in files, logs or diagnostics. When device
modules arrive, each gets its own Keychain service and can reach only its own
credentials.

*Enforced by:* review. *Gap:* per-module scoping does not exist yet, because there is
only one module. It must exist before the second.

## Article 6 — A diagnostic must be safe to publish

The diagnostics report is designed to be pasted into a public issue. It carries no
light, room or scene names, no addresses and no coordinates, and identifies keys and
bridges only by fingerprint.

*Enforced by:* `tools/check-no-secrets.sh` in CI scans tracked text for real
addresses, MAC addresses and coordinates. A test asserts that fingerprints disclose
neither the value nor its prefix.

## Article 7 — The user is told when something fails

Every failure path surfaces to the user and to the log. A swallowed failure makes the
app look broken.

*Enforced by:* review, plus the absence of any `catch {}` that only assigns state.
*Gap:* not machine-checked.

## Article 8 — Claims are measured, not asserted

Statements about behaviour are established by measurement, and the comment records
the measurement rather than the intention.

*Enforced by:* review standard only.

---

## How a change gets in

1. CI passes: both build variants, all tests, `check-boundaries.sh`,
   `check-no-secrets.sh`.
2. A human reviews it. `main` is protected: no direct pushes, no self-merge.
3. A change touching a transport, credentials, entitlements or the diagnostics report
   is **security-relevant** and says so in its description, naming the articles it
   touches.
4. New device support additionally states: what it talks to, on which ports, how it
   authenticates the device, what credentials it stores, and what it can prove about
   the device on the other end. "None" is acceptable — Kasa's legacy protocol has no
   authentication — but it must be stated, and the UI must not imply otherwise.

## How a release is published

Development happens in a private repository. The public repository receives
synthesised snapshot commits: each is built from the current tree alone, so private
history — which contains real addresses, device identifiers and light names — is
never pushed.

Snapshots land on `staging`, where CI runs, and reach `main` only through a pull
request that the same checks gate. `tools/publish.sh` performs this. Publishing does
not bypass the protection on `main`.

## What this cannot do

A contributor can still write a subtle bug, and no checklist catches that. These
articles make *structural* attacks expensive and conspicuous: exfiltration requires
adding a host or a network call, a dependency, or runtime code loading — each of
which CI sees. The remaining risk is ordinary code review.
