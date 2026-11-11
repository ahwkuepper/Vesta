#!/bin/bash
# Public Home releases never push private history or allow unattested signing.
# prepare: clean committed source -> unsigned hash manifest (no signing/tag/push)
# verify:  public tag -> independent rebuild -> manifest comparison
# sign:    verified public tag + exact CI attestation -> notarized installer
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PHASE="${1:-}"
VERSION="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 prepare|verify|sign MAJOR.MINOR.PATCH" >&2; exit 2; }
case "$PHASE" in prepare|verify|sign) ;; *) echo "Unknown phase." >&2; exit 2 ;; esac
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to the pinned Xcode}"
TAG="home-v$VERSION"
MANIFEST="release/$TAG.txt"
REPO=ahwkuepper/Vesta
if [ "$PHASE" = sign ]; then
    for SUFFIX in '' .sha256 .build.txt; do
        test ! -e "$ROOT/build/Vesta-Home-$VERSION-universal.dmg$SUFFIX" || { echo "Output already exists; choose a new version or preserve it elsewhere." >&2; exit 1; }
    done
fi
BASE=/private/tmp/vesta-home-verify
CANONICAL="$BASE/VestaHome"
mkdir "$BASE" || { echo "Canonical build directory is in use. Check $BASE before removing it." >&2; exit 1; }
trap 'rm -rf "$BASE"' EXIT

if [ "$PHASE" = prepare ]; then
    test -z "$(git status --porcelain)" || { echo "Commit the reviewed source snapshot first." >&2; exit 1; }
    test ! -e "$MANIFEST" || { echo "Manifest already exists; choose a new version." >&2; exit 1; }
    ./tools/check-no-secrets.sh
    ./tools/check-boundaries.sh
    python3 -B tools/test_public_tree.py
    swift test
    VESTA_CLASSIC=1 swift test
    ./nest/test.sh
    mkdir "$CANONICAL"
    git archive HEAD | tar -x -C "$CANONICAL"
else
    git clone --quiet --depth 1 --branch "$TAG" "https://github.com/$REPO.git" "$CANONICAL"
fi

cd "$CANONICAL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' home/Info.plist)" = "$VERSION" || { echo "Version must match home/Info.plist." >&2; exit 1; }
./tools/build-home-unsigned.sh
BIN="$CANONICAL/.build/apple/Products/Release/VestaHome"
HASH=$(shasum -a 256 "$BIN" | awk '{print $1}')
if [ "$PHASE" = prepare ]; then
    mkdir -p "$ROOT/release"
    cat > "$ROOT/$MANIFEST" <<EOF
# Vesta Home public beta; unsigned binary built at the canonical path.
# The public tag identifies the source. Signed DMG checksums ship as sidecars.
version: $VERSION
product: VestaHome
unsigned-sha256: $HASH
xcode-build: $(cat .xcode-build-version)
macos-target: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' home/Info.plist)
architectures: arm64 x86_64
EOF
    echo "Prepared $ROOT/$MANIFEST. Commit it to the reviewed snapshot."
    echo "Promote a public snapshot through CI, then tag PUBLIC main as $TAG. Never push a private tag."
    exit 0
fi
test -f "$MANIFEST" || { echo "Public tag has no Home manifest." >&2; exit 1; }
test "$HASH" = "$(awk '/^unsigned-sha256:/ {print $2}' "$MANIFEST")" || { echo "Unsigned binary does not match the public manifest." >&2; exit 1; }
test "$(cat .xcode-build-version)" = "$(awk '/^xcode-build:/ {print $2}' "$MANIFEST")" || { echo "Manifest toolchain mismatch." >&2; exit 1; }
echo "MATCH: public $TAG rebuilt as $HASH"
[ "$PHASE" = verify ] && exit 0
# package-home.sh independently requires the exact public-tag attestation.
./tools/package-home.sh --public "$TAG"
mkdir -p "$ROOT/build"
for FILE in build/Vesta-Home-"$VERSION"-universal.dmg*; do
    test ! -e "$ROOT/$FILE" || { echo "Refusing to overwrite $ROOT/$FILE" >&2; exit 1; }
done
cp build/Vesta-Home-"$VERSION"-universal.dmg* "$ROOT/build/"
echo "Public beta candidate packaged in $ROOT/build. See home/RELEASING.md before uploading."
