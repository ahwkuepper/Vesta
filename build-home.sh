#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source nest/toolchain.sh
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
IDENTITY="${VESTA_SIGNING_IDENTITY:-Vesta Development}"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
    echo "A stable Vesta Development signing identity is required for saved Keychain access." >&2
    exit 1
fi
swift build --product VestaHome \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/home/Info.plist"
BIN_DIR=$(swift build --show-bin-path)
APP="$PWD/.build/home/Vesta Home.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/VestaHome" "$APP/Contents/MacOS/VestaHome"
cp home/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.VestaHome \
    --options runtime --timestamp=none --entitlements home/entitlements.plist "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
