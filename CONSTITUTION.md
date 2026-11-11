# Vesta's constitution

Vesta controls lights in people's homes and runs on their personal machines. It is
open source, so its contributors are strangers.

Every article names the mechanism that enforces it. Where an article is unenforced,
it says so; those gaps are where to spend effort next.

---

## Article 1 — Nothing leaves the machine

Vesta talks to devices on the local network and to nothing else. No telemetry, crash
reporting, update checks, analytics, or remote configuration.

The separately built, opt-in `nest/` command-line companion is an explicit exception:
the user authorized Google Nest cloud access. It only posts OAuth exchanges to
`oauth2.googleapis.com` and reads devices from `smartdevicemanagement.googleapis.com`
over HTTPS port 443. Its consent link opens Google's Nest permissions page in the
user's browser. Neither Vesta nor Vesta Kasa links this package. The reader's default
transport rejects thermostat write endpoints; it has no telemetry or background service. Its transport checks
the HTTP method, host, and path and rejects redirects; tests cover that allowlist.

The user also authorized **Vesta Home**, a separate, opt-in combined application.
It links the same Nest source with control explicitly enabled. In addition to the
reader endpoints, it may POST only the five thermostat commands (heat, cool, range,
mode and Eco) to a device returned by the authorized project's fresh device read.
The CLI's default client still rejects every command endpoint. Home uses local Hue
and Kasa transports and each provider's existing scoped Keychain service; it never
copies credentials to preferences. Its connection screen states that Nest uses
Google. Home polls Nest once a minute, stops polling after an error until a manual
retry, and never retries an ambiguous write. No startup action changes device state.

*Enforced by:* `tools/check-boundaries.sh` fails the build if a hard-coded host
appears in `Sources/`, or if a networking or subprocess API is used outside a
reviewed transport module. Runs in CI on every push and pull request.

*What that is worth:* the check is a token scan, not a network property. It makes
egress conspicuous in a diff — anything added has to appear as a recognisable API
call in a reviewed file — but a determined contributor can compute a destination at
runtime. Treat it as a tripwire, not a wall.

*Gap:* the `com.apple.security.network.client` entitlement permits any outbound
connection; macOS has no LAN-only entitlement. The check is structural, not a kernel
guarantee. A choke point rejecting non-private address ranges would close this and is
the highest-value outstanding security work.

*Note on updates:* Sparkle is the standard macOS answer and is excluded twice over —
it is a third-party dependency (Article 2) and it polls a remote appcast (Article 1).
Neither is negotiable. How users learn about new versions is documented in the
README instead: Homebrew, a watch subscription, or a feed reader, each of which puts
the network call in software the user already chose.

## Article 2 — No third-party dependencies

Apple frameworks only. A dependency runs with the app's entitlements, sandbox and
Keychain access.

*Enforced by:* `check-boundaries.sh` fails if `Package.swift` declares a remote
package or a `binaryTarget`, or if `Package.resolved` exists.

Where a dependency becomes unavoidable, vendor it into the tree so it is reviewed
like any other code.

## Article 3 — Device modules are compiled in, never loaded

A plug-in bundle inherits the host app's entitlements, sandbox and Keychain, so there
is no boundary between the app and a plug-in it loads. Device support is added as a
target in this repository, through review.

*Enforced by:* `check-boundaries.sh` fails on `dlopen`, `dlsym`, `Bundle(path:)`,
`Bundle(url:)`, `Bundle(identifier:)` and `NSClassFromString`.

Targets are also layered, and the layering is checked: the domain imports no
transport and no UI framework, the command line does not import the interface, and
a transport does not import its callers. A device module therefore cannot reach the
interface, and the domain cannot be quietly taught about a protocol.

## Article 4 — Device input is untrusted

Anything arriving from the network is attacker-controlled, including from devices the
user owns. Decoding must be total: no force unwraps, no unbounded reads, a timeout on
everything.

*Enforced by:* `check-boundaries.sh` fails on `try!` and `as!` in `Sources/`.
Contract tests decode recorded payloads, including malformed ones. Responses are
capped at 8 MB and the data session has a bounded resource timeout, so a host that
answers slowly forever cannot hold a request open or exhaust memory.

## Article 5 — Credentials are scoped and never on disk

Persisted application credentials live in provider-specific Keychain services,
never preferences, logs or diagnostics. Hue, Kasa and Nest have separate stores;
their transports receive only their own credentials. Home composes all three.
This is a source boundary, not isolation from malicious code in the same process.
User-downloaded OAuth client JSON is a setup input; users must delete or protect
that file themselves after import. It is never bundled or copied to preferences.

*Enforced by:* transport review and provider store implementations. Cross-process
Nest authorization must not overlap with the standalone reader's authorization.

## Article 6 — A diagnostic must be safe to publish

The diagnostics report is designed to be pasted into a public issue. It carries no
light, room or scene names, no addresses and no coordinates, and identifies keys and
bridges only by fingerprint.

*Enforced by:* `tools/check-no-secrets.sh` scans tracked and nonignored untracked
text, including fixtures, for addresses, MACs, bridge IDs, coordinates, private
keys and common credential formats. It reports locations without matched values.
Binary assets require reviewed hashes in `tools/public-assets.sha256`. Regression
tests cover untracked leaks and redaction. This gate does not inspect private Git
history; publication must use a snapshot without that history. Pattern matching
cannot establish the absence of every possible secret.

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
2. `main` is protected: changes arrive by pull request, CI must pass before merge,
   and force-pushes and deletions are refused.

   *Gap:* branch protection does not require an approving review. With one
   maintainer there is no second reviewer, so a required approval could never be
   satisfied and self-merge is possible today. This must close before the repository
   accepts pull requests from anyone but the maintainer.
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

A pull request from outside therefore lands by being applied to the private tree and
republished, not by being merged — merging it would be undone by the next snapshot.
[CONTRIBUTING.md](CONTRIBUTING.md) says so plainly, because discovering it after the
fact would read as bad faith.

## What this cannot do

A contributor can still write a subtle bug, and no checklist catches that. These
articles make *structural* attacks expensive and conspicuous: exfiltration requires
adding a host or a network call, a dependency, or runtime code loading — each of
which CI sees. The remaining risk is ordinary code review.
