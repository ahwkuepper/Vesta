# Vesta Home public beta releases

Home uses `home-vMAJOR.MINOR.PATCH` tags. The original Hue-only app keeps `v*` tags
and its existing workflow. Never push private repository history or private tags.
The personal `package-home.sh` path does not provide public build provenance.

## Prepare a reviewable candidate

1. Update `home/Info.plist` version/build and `home/CHANGELOG.md`.
2. Run `tools/prepare-public-snapshot.sh .build/public-home-candidate`. This copies
   tracked and nonignored untracked files into a new local repository, checks that
   exact tree, and makes a root commit without private ancestry. It never pushes.
   Existing destination directories are refused. Review the snapshot before use.
3. From that snapshot, set `DEVELOPER_DIR` to the released Xcode whose build is in
   `.xcode-build-version`, then run `tools/release-home.sh prepare VERSION`.
   It runs both Swift test variants, Nest tests and publication checks, builds the
   unsigned universal executable, and writes `release/home-vVERSION.txt`.
4. Commit the manifest in the snapshot. Record actual results in
   `home/VALIDATION.md`. Source can be promoted after review and CI. Complete
   fresh-install and device checks using the final signed candidate before making
   an installer release; do not mark hardware checks passed from simulations.

The binary is built at `/private/tmp/vesta-home-verify/VestaHome`, by the same
`tools/build-home-unsigned.sh` in preparation, CI and verification. Preparation
refuses an occupied canonical directory. Do not run those operations concurrently.

## Publish source, then attest

Add the public repository as the snapshot's `public` remote. Use `tools/publish.sh`
to synthesize a commit parented only on public history and push it to `staging`.
Open a promotion PR, inspect the diff and wait for CI. Merge through the repository's
required review/checks. Verify branch protections include CI and code-owner review;
CODEOWNERS alone does not enforce approval.

After promotion, fetch public main and verify it contains the reviewed manifest.
Create the tag on **public main**, never a private commit:

```sh
git fetch --prune public
git push public public/main:refs/tags/home-vVERSION
```

Replace VERSION with the numeric release version. `attest-home.yml` builds on a
GitHub-hosted runner and publishes provenance only if the exact pinned Xcode is
available and the unsigned hash matches the manifest. Missing toolchain or any
mismatch is a release blocker, not a reason to bypass verification.

## Sign and verify the installer

Check `xcrun notarytool history --keychain-profile vesta-notary` before signing.
Then run `tools/release-home.sh sign VERSION`. It clones the public tag, rebuilds,
checks the manifest and verifies GitHub provenance bound to that tag, commit and
Home workflow. There is no unsigned-provenance override. Signing/notarization
credentials remain in the maintainer's local Keychain.

The script signs and notarizes the app and DMG, staples both, checks Gatekeeper and
writes portable checksum/build sidecars into `build/`. It refuses existing outputs.
Mount the final DMG read-only, inspect the app and included instructions/privacy,
and verify a fresh install. Keep the app artifact that was tested; do not rebuild
it before uploading. Attach the DMG, checksum, build metadata and source manifest
to a GitHub **prerelease**, with `home/CHANGELOG.md` as release notes. No Homebrew
Home cask exists yet; do not replace the Hue cask with this different application.

Anyone can independently rebuild the unsigned executable:

```sh
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer tools/release-home.sh verify VERSION
```

A successful comparison verifies the unsigned build input, not the bytes of a
signed download. Verify the downloaded DMG's checksum, Developer ID signature and
Gatekeeper acceptance separately. Apple signing and notarization do not constitute
a security audit or hardware compatibility certification.
