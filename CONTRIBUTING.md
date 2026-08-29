# Contributing

Read [CONSTITUTION.md](CONSTITUTION.md) first. It states the invariants every change
is held to and names what enforces each one. The checklist in the pull request
template is not optional for anything touching a transport, credentials,
entitlements or the diagnostics report.

## How a change actually lands

This matters more than anything else here, so it comes first.

Development happens in a private repository. This public repository receives
**synthesised snapshot commits**: each is built from the current tree alone, with no
development history, because that history contains real network addresses, device
identifiers and the names of lights in someone's home.

A consequence you need to know before spending time on a pull request:

1. Open a pull request against `main` as normal. CI runs against your diff alone.
2. It is reviewed here, like any project.
3. If accepted, the change is applied to the private tree, crediting you and linking
   your pull request, and published as the next snapshot.
4. Your pull request is then **closed with a link to the commit that carries your
   change**, rather than merged with GitHub's button.

That last step is not a rejection. Merging directly would work for about a day —
the next snapshot rebuilds `main` from the private tree and would silently discard
it. Closing the pull request is how the change survives.

Treat a pull request here as a reviewed patch proposal. The code lands and you are
credited; landing takes one manual step on this end.

## Reporting

Open an issue for bugs and ideas. For anything that looks like a security or privacy
problem, use the private advisory described in [SECURITY.md](SECURITY.md) rather than
a public issue.

For anything larger than a small fix, open an issue first. [ROADMAP.md](ROADMAP.md)
records what is already planned and what has already been ruled out.

## Building and testing

```bash
./tools/make-signing-identity.sh     # once
./build.sh && open build/Vesta.app
swift test
```

Full prerequisites are in the [README](README.md#build). The tests need no bridge and
no hardware: `Tests/VestaBridgeTests` decodes recorded bridge responses, and
`SimulatedTransport` backs the rest.

Run the same checks CI runs before opening a pull request. Failing locally costs a
second; failing in CI costs a round trip.

```bash
./tools/check-boundaries.sh && ./tools/check-no-secrets.sh
```

Both build variants must compile — `swift build` and
`VESTA_MACOS_TARGET=14.0 swift build`. Building one is not building the tree.

## Scope

Vesta talks to a Philips Hue Bridge, and to Hue bulbs over Bluetooth where they are
free to bond.

[SECURITY.md](SECURITY.md) lists what has to exist before a device backend from
someone else can be accepted: an egress choke point, declared per-module
capabilities, scoped credentials, and a stated device-authentication model. Until
those exist, propose new device support as an issue rather than a finished pull
request — it will not be merged, and that is a property of the project rather than a
judgement of the code.

## Style

No formatter is configured; match the surrounding code. Comments explain why a
decision was made, and record measurements rather than intentions — see Article 8.
Development history belongs in commit messages, not in the source.

## Licence and sign-off

Contributions are licensed under this project's [Apache-2.0 licence](LICENSE), on
the terms of section 5 of that licence: what you send in goes out under the same
licence unless you say otherwise in writing.

There is no CLA. Every commit **in a pull request** must carry a `Signed-off-by`
line certifying you have the right to submit it under that licence — the [Developer
Certificate of Origin](https://developercertificate.org). `git commit -s` adds it.
Snapshot commits published from the private tree are exempt, since they have no
outside author to certify.

You keep the copyright in what you write. Vesta stays open source under Apache-2.0.
The maintainer may also distribute the software, including your contribution, under
separate commercial terms — a paid build, for instance — as Apache-2.0 permits. That
does not remove or narrow anyone's rights under Apache-2.0, and it never will: every
version published under it stays available under it.
