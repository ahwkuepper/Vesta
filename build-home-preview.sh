#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source nest/toolchain.sh
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
swift build --product VestaHomePreview \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/home-preview/Info.plist"
BIN_DIR=$(swift build --show-bin-path)
APP="$PWD/.build/home-preview/Vesta Home Preview.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/VestaHomePreview" "$APP/Contents/MacOS/VestaHomePreview"
cp home-preview/Info.plist "$APP/Contents/Info.plist"
IDENTITY="${VESTA_SIGNING_IDENTITY:-Vesta Development}"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then IDENTITY="-"; fi
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.VestaHomePreview \
    --options runtime --timestamp=none --entitlements home-preview/entitlements.plist "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
