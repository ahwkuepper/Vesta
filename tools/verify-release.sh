#!/bin/bash
# Rebuild a released binary from source and compare it with the published hash.
#
# What this proves: the unsigned Vesta binary in a given release was built from the
# source at that tag, by a toolchain you can name, and nothing else was added.
#
# What it does not prove: that the signed .dmg you downloaded is that binary. A code
# signature embeds a certificate and a timestamp from Apple, so a signed bundle is
# never byte-identical twice and only the maintainer can produce one. The unsigned
# binary is the honest comparison point.
#
# Usage: tools/verify-release.sh v0.1.0
set -euo pipefail

TAG="${1:-}"
if [ -z "$TAG" ]; then
    echo "usage: $0 <tag>    e.g. $0 v0.1.0" >&2
    exit 2
fi

REPO="${VESTA_REPO:-https://github.com/ahwkuepper/Vesta.git}"

# The build path is embedded in the binary, so it is part of the input. Two clones
# at paths differing by one character produce binaries differing in tens of
# thousands of bytes. Every verifier therefore builds at the same fixed path.
CANONICAL=/private/tmp/vesta-verify/Vesta

echo "==> verifying $TAG"
echo "    source:    $REPO"
echo "    build path: $CANONICAL  (fixed on purpose — see the comment in this script)"

rm -rf /private/tmp/vesta-verify
mkdir -p /private/tmp/vesta-verify
git clone --quiet --depth 1 --branch "$TAG" "$REPO" "$CANONICAL"

cd "$CANONICAL"

MANIFEST="release/$TAG.txt"
if [ ! -f "$MANIFEST" ]; then
    echo "error: $TAG carries no release manifest at $MANIFEST." >&2
    exit 1
fi

want_hash=$(awk '/^unsigned-sha256:/ {print $2}' "$MANIFEST")
want_xcode=$(awk '/^xcode-build:/ {print $2}' "$MANIFEST")
want_target=$(awk '/^macos-target:/ {print $2}' "$MANIFEST")

echo "    published: $want_hash"
echo "    toolchain: Xcode $want_xcode, target $want_target"

have_xcode=$(defaults read "$(dirname "$(dirname "${DEVELOPER_DIR:?set DEVELOPER_DIR to the Xcode you are verifying with}")")/Contents/version" \
    ProductBuildVersion 2>/dev/null || echo unknown)

if [ "$have_xcode" != "$want_xcode" ]; then
    echo
    echo "warning: this is Xcode $have_xcode, the release used $want_xcode."
    echo "         The binary is only bit-identical on the same toolchain, so a"
    echo "         mismatch below tells you nothing. Install $want_xcode to compare."
    echo
fi

# Both --arch flags are load-bearing, and not only because the release is universal.
# A multi-arch build goes through a different pipeline from a plain `swift build`,
# and only the multi-arch one is deterministic: the single-arch pipeline leaves the
# object files' modification times in the binary's debug map, so two builds minutes
# apart at the same path differ. Drop an --arch here to "simplify" and this script
# starts reporting mismatches that read exactly like tampering. Measured, both ways.
echo "==> building"
VESTA_MACOS_TARGET="$want_target" swift build -c release --product Vesta \
    --arch arm64 --arch x86_64 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$CANONICAL/Info.plist" >/dev/null

# The universal product, not the .build/release symlink: that points at the
# single-arch directory, so comparing it would fail against every published hash.
BIN=.build/apple/Products/Release/Vesta
if [ ! -f "$BIN" ]; then
    echo "error: no universal binary at $BIN after building." >&2
    exit 1
fi
got_hash=$(shasum -a 256 "$BIN" | awk '{print $1}')

echo
echo "    published: $want_hash"
echo "    rebuilt:   $got_hash"
echo

if [ "$got_hash" = "$want_hash" ]; then
    echo "MATCH — this release was built from the source at $TAG."
    exit 0
fi

echo "MISMATCH."
if [ "$have_xcode" != "$want_xcode" ]; then
    echo "Most likely because the toolchain differs: $have_xcode vs $want_xcode."
    exit 1
fi
echo "Same toolchain, same tag, different bytes. That is worth reporting:"
echo "  https://github.com/ahwkuepper/Vesta/security/advisories/new"
exit 1
