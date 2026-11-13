#!/bin/bash
# Private packaging by default; --public requires exact public-tag provenance.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"
IDENTITY="${VESTA_SIGNING_IDENTITY:-Developer ID Application: Andreas Kupper (9UMFUK9G2Y)}"
PROFILE="${VESTA_NOTARY_PROFILE:-vesta-notary}"
PUBLIC_TAG=""
if [ "${1:-}" = --public ] && [ $# -eq 2 ]; then
    PUBLIC_TAG="$2"
elif [ $# -ne 0 ]; then
    echo "Usage: $0 [--public home-vVERSION]" >&2; exit 2
fi
XCODE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$DEVELOPER_DIR/../version.plist")
test "$XCODE_BUILD" = "$(cat .xcode-build-version)" || { echo "Use the pinned Xcode toolchain." >&2; exit 1; }
case "$IDENTITY" in 'Developer ID Application:'*) ;; *) echo "Developer ID signing is required." >&2; exit 1 ;; esac
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" || { echo "Signing identity unavailable." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' home/Info.plist)
SDK=$(xcrun --sdk macosx --show-sdk-version)
WORK="$ROOT/.build/home-personal"
APP="$WORK/stage/Vesta Home.app"
OUTPUT="$ROOT/build/Vesta-Home-$VERSION-universal.dmg"
mkdir -p "$WORK" "$ROOT/build"
test ! -e "$OUTPUT" || { echo "Installer already exists at $OUTPUT; preserve it and choose a new version." >&2; exit 1; }

./tools/check-boundaries.sh
./tools/check-no-secrets.sh
if [ -n "$PUBLIC_TAG" ]; then
    test "$PUBLIC_TAG" = "home-v$VERSION"
    test "$ROOT" = /private/tmp/vesta-home-verify/VestaHome
    test -z "$(git status --porcelain)"
    test "$(git rev-parse HEAD)" = "$(git rev-parse "$PUBLIC_TAG^{commit}")"
    BIN="$ROOT/.build/apple/Products/Release/VestaHome"
    test "$(shasum -a 256 "$BIN" | awk '{print $1}')" = "$(awk '/^unsigned-sha256:/ {print $2}' "release/$PUBLIC_TAG.txt")"
    gh attestation verify "$BIN" --repo ahwkuepper/Vesta \
        --signer-workflow ahwkuepper/Vesta/.github/workflows/attest-home.yml \
        --source-ref "refs/tags/$PUBLIC_TAG" --source-digest "$(git rev-parse HEAD)" \
        --deny-self-hosted-runners
    DISTRIBUTION="public beta"
    PROVENANCE="Public source: $PUBLIC_TAG ($(git rev-parse HEAD)); exact unsigned binary verified against GitHub CI attestation."
else
    echo "Building Vesta Home $VERSION for Apple silicon and Intel with Xcode $XCODE_BUILD"
    swift build --scratch-path "$WORK/swift" -c release --product VestaHome --arch arm64 --arch x86_64 \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/home/Info.plist"
    BIN="$WORK/swift/apple/Products/Release/VestaHome"
    DISTRIBUTION="private distribution"
    PROVENANCE="Built from the local working tree; no public release or CI attestation."
fi
test -f "$BIN"
lipo "$BIN" -verify_arch arm64 x86_64
for ARCH in arm64 x86_64; do
    LINKED_SDK=$(otool -arch "$ARCH" -l "$BIN" | awk '$1 == "sdk" {print $2; exit}')
    test "${LINKED_SDK%%.*}" = "${SDK%%.*}" || { echo "Incorrect linked SDK for $ARCH: $LINKED_SDK" >&2; exit 1; }
done
UNSIGNED_HASH=$(shasum -a 256 "$BIN" | awk '{print $1}')
# Never carry stale resources or credentials from an earlier staging directory.
rm -rf "$WORK/stage"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/VestaHome"
cp home/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.VestaHome \
    --options runtime --timestamp --entitlements home/entitlements.plist "$APP"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" "$WORK/Vesta-Home.zip"
echo "Submitting app to Apple"
xcrun notarytool submit "$WORK/Vesta-Home.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/app-notary.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); sys.exit(0 if r.get("status")=="Accepted" else 1)' "$WORK/app-notary.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ln -sfn /Applications "$WORK/stage/Applications"
cp home/INSTALL.txt "$WORK/stage/READ ME.txt"
cp home/PRIVACY.md "$WORK/stage/PRIVACY.md"
hdiutil create -quiet -volname "Vesta Home" -srcfolder "$WORK/stage" -format UDZO "$OUTPUT"
codesign --force --sign "$IDENTITY" --timestamp "$OUTPUT"
echo "Submitting installer to Apple"
xcrun notarytool submit "$OUTPUT" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/dmg-notary.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); sys.exit(0 if r.get("status")=="Accepted" else 1)' "$WORK/dmg-notary.json"
xcrun stapler staple "$OUTPUT"
xcrun stapler validate "$OUTPUT"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUTPUT"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$OUTPUT")") > "$OUTPUT.sha256"
cat > "$OUTPUT.build.txt" <<EOF
Vesta Home $VERSION — $DISTRIBUTION
Architectures: arm64 x86_64
Minimum macOS: 14.0
Xcode build: $XCODE_BUILD
SDK: $SDK
Unsigned executable SHA-256: $UNSIGNED_HASH
Signing identity: $IDENTITY
App and disk image: notarized and stapled; Gatekeeper accepted
$PROVENANCE
EOF
echo "Installer ready: $OUTPUT"
