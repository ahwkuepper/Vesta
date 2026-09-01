# Releasing

One maintainer, one machine, one certificate. This document exists so that is
recoverable rather than fatal: anyone with their own Developer ID can follow it.

## Once

- Apple Developer Program membership, and a **Developer ID Application** certificate.
- `xcrun notarytool store-credentials "vesta-notary"` with an App Store Connect API
  key. It is stored in the keychain — never committed, never uploaded, never in CI.
- A **released** Xcode with its licence accepted. Not a beta. Record its build number
  in `.xcode-build-version`; `build.sh --release` refuses to build against anything
  else, because the published hash is only reproducible on the pinned toolchain.
- A Philips Hue Bridge on the network.

## Why signing happens here and not in CI

The Developer ID key is the most valuable thing this project has. Whoever holds it
can sign software as its author, and a certificate Apple revokes takes every past
release down with it. Putting it in GitHub Actions would mean exporting it — creating
an extractable copy of an asset that is currently not extractable — and decrypting it
on a runner, on every release, alongside the notarisation key.

Keeping the two credentials apart means an attacker needs two compromises, and
`xcrun notarytool history` stays a tripwire that fires on the first. Run it as the
first step of every release and read it.

CI does the half that needs no secret: it rebuilds the unsigned binary and records
its hash. The release refuses to sign anything that hash does not match.

## Before tagging

Paste the output into the promotion pull request.

- [ ] `swift test` passes on both variants.
- [ ] `./tools/check-boundaries.sh && ./tools/check-no-secrets.sh`.
- [ ] Hardware suite against a real bridge — CI cannot run these, and they are the
      only check that the transport still works: `--verify-bridge`, `--test-lights`,
      `--test-scene-switch`, `--test-relocate`, `--test-scenes`.
- [ ] `CHANGELOG.md` has an entry written by a human.

## Release, in two phases

The order cannot be collapsed. CI attests the unsigned binary built from the tag;
the tag cannot exist until the manifest records the hash; the hash is not known
until the binary is built. Signing comes last so that it can refuse anything CI did
not attest.

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # never a beta
    tools/release.sh prepare 0.1.0

    tools/publish.sh --message "Release 0.1.0"
    # merge the promotion PR, then tag the commit that landed on public main.
    # Tag the public commit, never the local tag: `git push public v0.1.0` would
    # push the private commit it points at, and the whole private history behind
    # it, into the public repository.
    git fetch --prune public
    git push public public/main:refs/tags/v0.1.0
    # wait for the attest workflow to finish

    tools/release.sh sign 0.1.0

    # commit the manifest's dmg hash, republish, then
    gh release create v0.1.0 --repo ahwkuepper/Vesta --prerelease \
        --notes-file CHANGELOG.md build/Vesta-0.1.0.dmg release/v0.1.0.txt

## Why releases are built at a fixed path

The absolute build path is embedded in the binary, so it is part of the input, and
every rebuild — `tools/release.sh`, `tools/verify-release.sh`, the attest workflow —
uses `/private/tmp/vesta-verify/Vesta`. Two clones at paths differing by one
character produce binaries differing in tens of thousands of bytes.

This is a workable design, not a good one: it asks every verifier to build somewhere
specific. The obvious fix does not work, and was measured rather than assumed:

- `-file-prefix-map` (plus `-ffile-prefix-map` for C) removes the source paths, but
  not the linker's debug map. A universal binary carries 42 OSO entries holding the
  absolute paths of the object files.
- `-oso_prefix` does fix those, and works for a single-arch build. It cannot be
  delivered to a universal link: passed via `-Xlinker` the linker reads the prefix
  as an input file and fails to mmap it; routed through `-Xswiftc -Xlinker` it is
  silently dropped.
- Stripping afterwards is too late. `LC_UUID` is computed at link time over content
  that still contained the paths, so `strip -S` closes the gap from 60,164 differing
  bytes to 102 — the two per-arch UUIDs and the signature — and no further.

So path-independence needs a linker flag SwiftPM cannot pass to a universal link.
If a future toolchain plumbs `-oso_prefix` through, verification could stop caring
where it runs, and the pinned path could go.

One thing that is *not* a problem: multi-arch builds are deterministic over time.
Two builds minutes apart at the same path are byte-identical. Single-arch builds are
not — see the comment in `tools/verify-release.sh`.

## Two tags, deliberately

The tag in the **public** repository is authoritative: it is what a release is
verified against and what `verify-release.sh` checks out. The identically named tag
in the **private** repository points at the commit whose tree produced the snapshot,
and exists only so the maintainer can rebuild. Never tag `staging` — it is
force-pushed, and a tag there can end up pointing at an orphaned commit.

## If the key is compromised

1. Revoke the certificate in the developer portal.
2. Contact Apple Developer Support and product-security@apple.com.
3. Reissue, re-sign, re-notarise, re-release.
4. Publish an incident note listing the known-good SHA-256 of every prior release.

Step 4 is why the per-release manifest exists. After a key theft it is the only way
a user can tell their copy from an attacker's.

## If you are taking this over

You cannot use the original maintainer's certificate and should not try. Enrol, get
your own Developer ID, and set `VESTA_SIGNING_IDENTITY`. Users will see a different
signing identity, which is correct and honest — say so in the release notes for the
first build you sign.
