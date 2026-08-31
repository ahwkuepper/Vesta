#!/bin/bash
# Cut a release, in two phases.
#
#   tools/release.sh prepare 0.1.0    stamp, build unsigned, write the manifest, tag
#   ... publish, push the tag, let CI attest the unsigned hash ...
#   tools/release.sh sign 0.1.0       verify the attestation, sign, notarise, package
#
# Two phases because the order matters and cannot be collapsed. CI attests the
# unsigned binary built from the tag; the tag cannot exist until the manifest
# records the hash; the hash cannot be known until the binary is built. Signing
# last is what lets the signing step refuse anything CI did not attest.
#
# Signing and notarisation happen here, on the maintainer's machine, and nowhere
# else. The Developer ID private key is the most valuable thing this project has:
# whoever holds it can sign software as its author, and a certificate Apple revokes
# takes every past release down with it. It is not going into CI. See SECURITY.md.
set -euo pipefail
cd "$(dirname "$0")/.."

PHASE="${1:-}"
VERSION="${2:-}"
if [ -z "$PHASE" ] || [ -z "$VERSION" ]; then
    echo "usage: $0 prepare|sign <version>    e.g. $0 prepare 0.1.0" >&2
    exit 2
fi
TAG="v$VERSION"
# The universal product, not the .build/release symlink — that points at the
# single-arch directory, so hashing it would record a binary the DMG does not carry.
BIN=".build/apple/Products/Release/Vesta"

# The shipped variant. macOS 14 reaches every machine the README claims; the Liquid
# Glass variant stays a build-from-source option.
export VESTA_MACOS_TARGET="${VESTA_MACOS_TARGET:-14.0}"

xcode_build() {
    defaults read "$(dirname "$(dirname "${DEVELOPER_DIR:?set DEVELOPER_DIR}")")/Contents/version" \
        ProductBuildVersion 2>/dev/null || echo unknown
}

build_unsigned() {
    # Deliberately not build.sh: that signs, and the whole point of this phase is to
    # produce the artefact CI can independently reproduce before anyone signs it.
    swift build -c release --product Vesta --arch arm64 --arch x86_64 \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
        -Xlinker "$PWD/Info.plist"
}

case "$PHASE" in

prepare)
    [ -n "$(git status --porcelain)" ] && { echo "error: working tree is dirty." >&2; exit 1; }

    case "${DEVELOPER_DIR:-}" in
        "")           echo "error: set DEVELOPER_DIR explicitly for a release." >&2; exit 1 ;;
        *Xcode-beta*) echo "error: refusing to release from a beta Xcode." >&2; exit 1 ;;
    esac

    echo "==> checks"
    ./tools/check-boundaries.sh >/dev/null
    ./tools/check-no-secrets.sh >/dev/null
    swift test >/dev/null 2>&1 || { echo "error: tests failed." >&2; exit 1; }
    echo "    boundaries, secrets and tests pass"

    echo
    echo "The hardware suite cannot run in CI and is the only check that the transport"
    echo "still works against a real bridge:"
    echo "    --verify-bridge  --test-lights  --test-scene-switch  --test-relocate"
    read -r -p "Have they passed? [y/N] " ok
    [ "$ok" = "y" ] || { echo "aborted."; exit 1; }

    echo "==> stamping $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
    # Monotonic, and needs no stored counter that could be lost.
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date -u +%Y%m%d%H%M)" Info.plist

    echo "==> building unsigned, universal"
    build_unsigned
    UNSIGNED_HASH=$(shasum -a 256 "$BIN" | awk '{print $1}')

    mkdir -p release
    cat > "release/$TAG.txt" <<MANIFEST
# Vesta $VERSION — what was built, and from what.
#
# tools/verify-release.sh rebuilds the unsigned binary from this tag and compares it
# with unsigned-sha256. It is bit-for-bit reproducible given the same source, Xcode,
# deployment target, architectures, and absolute build path — the script pins the
# path, because the path is embedded in the binary.
#
# The commit is whatever this tag points at — a hash cannot name the tree that
# contains it.
#
# dmg-sha256 is an integrity check on one artefact, not a reproducibility claim: a
# signature embeds a certificate and an Apple timestamp, so a signed bundle is never
# byte-identical twice and only the maintainer can produce one.

version:         $VERSION
unsigned-sha256: $UNSIGNED_HASH
dmg-sha256:      PENDING
xcode-build:     $(xcode_build)
macos-target:    $VESTA_MACOS_TARGET
architectures:   arm64 x86_64
MANIFEST

    # No commit hash in the manifest: it lives inside the tree it would describe,
    # so writing it changes the tree and therefore the commit. The tag is the
    # identifier, and verify-release.sh clones by tag.
    git add Info.plist "release/$TAG.txt"
    git commit -q -m "Release $VERSION"
    git tag -f "$TAG" -m "Vesta $VERSION" >/dev/null

    echo
    echo "prepared $TAG — unsigned hash $UNSIGNED_HASH"
    echo
    echo "Next:"
    echo "  tools/publish.sh --message \"Release $VERSION\""
    echo "  # merge the promotion PR, then push the tag so CI can attest it:"
    echo "  git push public $TAG:refs/tags/$TAG"
    echo "  # wait for the attest workflow, then:"
    echo "  tools/release.sh sign $VERSION"
    ;;

sign)
    [ -f "release/$TAG.txt" ] || { echo "error: run '$0 prepare $VERSION' first." >&2; exit 1; }

    echo "==> rebuilding to confirm the tree still produces the attested binary"
    build_unsigned
    WANT=$(awk '/^unsigned-sha256:/ {print $2}' "release/$TAG.txt")
    GOT=$(shasum -a 256 "$BIN" | awk '{print $1}')
    [ "$WANT" = "$GOT" ] || {
        echo "error: this tree no longer builds the binary recorded in the manifest." >&2
        echo "       manifest $WANT" >&2
        echo "       rebuilt  $GOT" >&2
        exit 1
    }

    # What makes a compromise of this machine detectable: a backdoored binary will
    # not match the hash CI recorded in a public transparency log, so an attacker
    # would need GitHub's OIDC as well. Without this check the workflow is decoration.
    echo "==> checking the CI attestation"
    if gh attestation verify "$BIN" --repo ahwkuepper/Vesta >/dev/null 2>&1; then
        echo "    attested — CI built this exact binary from $TAG"
    else
        echo
        echo "warning: no CI attestation matches this binary. Either the attest" >&2
        echo "         workflow has not finished for $TAG, or this machine did not" >&2
        echo "         build what CI built." >&2
        read -r -p "Sign anyway? [y/N] " ok
        [ "$ok" = "y" ] || { echo "aborted."; exit 1; }
    fi

    echo "==> signing and notarising"
    ./build.sh release --release
    (cd build && rm -f Vesta.zip && zip -qr Vesta.zip Vesta.app)
    xcrun notarytool submit --keychain-profile "vesta-notary" --wait build/Vesta.zip
    xcrun stapler staple build/Vesta.app
    rm -f build/Vesta.zip

    echo "==> packaging"
    rm -f "build/Vesta-$VERSION.dmg"
    hdiutil create -quiet -volname "Vesta" -srcfolder build/Vesta.app \
        -ov -format UDZO "build/Vesta-$VERSION.dmg"
    DMG_HASH=$(shasum -a 256 "build/Vesta-$VERSION.dmg" | awk '{print $1}')
    sed -i '' "s|^dmg-sha256:.*|dmg-sha256:      $DMG_HASH|" "release/$TAG.txt"

    echo
    echo "built build/Vesta-$VERSION.dmg"
    echo "  unsigned: $WANT"
    echo "  dmg:      $DMG_HASH"
    echo
    echo "The manifest now records the dmg hash. Commit it, republish, and then:"
    echo "  gh release create $TAG --repo ahwkuepper/Vesta --prerelease \\"
    echo "      --notes-file CHANGELOG.md build/Vesta-$VERSION.dmg release/$TAG.txt"
    ;;

*)
    echo "unknown phase '$PHASE' — expected prepare or sign" >&2
    exit 2
    ;;
esac
