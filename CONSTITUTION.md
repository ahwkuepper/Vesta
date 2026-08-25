# Lumo's constitution

Lumo controls the lights in people's homes and runs on their personal machines. It
is open source, so its contributors are strangers, and it will outlive the attention
of whoever is reading this. These are the invariants that must hold regardless.

**A document does not enforce anything.** Prose has never stopped a malicious pull
request, and a rule nobody can check is a rule that quietly decays. So every article
below names the mechanism that enforces it. Where an article is currently unenforced,
it says so — those are the honest gaps, and they are where to spend effort next.

---

## Article 1 — Nothing leaves the machine

Lumo talks to devices on the local network and to nothing else. No telemetry, no
crash reporting, no update check, no analytics, no remote configuration, no
"anonymous usage statistics".

*Enforced by:* `tools/check-boundaries.sh` fails the build if any hard-coded host
appears in `Sources/`, or if network APIs are used outside a reviewed transport
module. Run in CI on every push and pull request.

*Gap:* the sandbox entitlement `com.apple.security.network.client` permits any
outbound connection; macOS has no LAN-only entitlement. The check is structural, not
a kernel guarantee. A single choke point that rejects non-private address ranges
would close this, and is the highest-value security work outstanding.

## Article 2 — No third-party dependencies

Apple frameworks only. Every dependency is code that runs with the app's
entitlements, its sandbox, and its Keychain access, contributed by people the user
never chose to trust.

*Enforced by:* `check-boundaries.sh` fails if `Package.swift` declares a remote
package or if `Package.resolved` exists.

*Consequence to accept:* some things must be written by hand rather than pulled in.
That is the price, and it is worth paying. Where a dependency becomes genuinely
unavoidable, vendor it into the tree so it is reviewed like any other code.

## Article 3 — Device modules are compiled in, never loaded

A plug-in bundle inherits the host app's entitlements, sandbox and Keychain. There
is no meaningful boundary between "the app" and "a plug-in it loads". Device support
is added as a target in this repository, through review.

*Enforced by:* `check-boundaries.sh` fails on `dlopen`, `Bundle(path:)` and
`NSClassFromString`.

## Article 4 — Device input is untrusted

Anything arriving from the network is attacker-controlled, including from devices
the user owns. Decoding must be total: no force unwraps, no unbounded reads, a
timeout on everything.

*Enforced by:* `check-boundaries.sh` fails on `try!` and `as!` in `Sources/`.
Contract tests decode recorded payloads, including malformed ones.

*Gap:* response size limits are not yet enforced.

## Article 5 — Credentials are scoped and never on disk

Secrets live in the Keychain, never in files, never in logs, never in a diagnostic.
When device modules arrive, each gets its own Keychain service and can reach only
its own credentials.

*Enforced by:* review today. *Gap:* per-module scoping does not exist yet, because
there is only one module. It must exist before the second.

## Article 6 — A diagnostic must be safe to publish

The diagnostics report exists to be pasted into a public issue. It carries no light,
room or scene names, no addresses, no coordinates, and identifies keys and bridges
only by fingerprint.

*Enforced by:* `tools/check-no-secrets.sh` in CI scans tracked text for real
addresses, MAC addresses and coordinates. A test asserts fingerprints disclose
neither the value nor its prefix.

*Why it is an article at all:* this was violated twice on the first day — a
MAC-derived bridge ID, then a home's latitude and longitude — both written into
files destined for publication, by someone who had just finished arguing that such
values must not be published.

## Article 7 — The user is told when something fails

A failure that is swallowed makes the app look broken and teaches the user not to
trust it. Every failure path surfaces to the user and to the log.

*Enforced by:* review, plus the absence of any `catch {}` that only assigns state.
*Gap:* not machine-checked.

## Article 8 — Claims are measured, not asserted

Statements about behaviour — "the popover is anchored", "glass is applied", "the
scene took effect" — are established by measurement and recorded with the evidence.
Comments in this repository cite the numbers that produced them because those
numbers cost hours to obtain.

*Enforced by:* nothing automatic. It is a review standard, and the reason the
codebase reads the way it does.

---

## How a change gets in

1. CI must pass: both build variants, all tests, `check-boundaries.sh`,
   `check-no-secrets.sh`.
2. A human reviews it. `main` is protected; no direct pushes, no self-merge.
3. A change touching a transport, credentials, entitlements or the diagnostics
   report is a **security-relevant change** and says so in its description, with the
   articles it touches.
4. New device support additionally states: what it talks to, on which ports, how it
   authenticates the device, what credentials it stores, and what it can prove about
   the thing on the other end. "None" is an acceptable answer — Kasa's legacy
   protocol has no authentication at all — but it must be stated, and the UI must not
   imply otherwise.

## What this cannot do

A determined contributor can still write a subtle bug, and no checklist catches
that. What these articles do is make the *structural* attacks expensive and
conspicuous: to exfiltrate anything you must add a host or a network call where CI
will see it, add a dependency where CI will see it, or load code at runtime where CI
will see it. The remaining risk is ordinary code review, done by people, carefully.
