#!/bin/bash
# Shared by preparation, independent verification and public CI.
set -euo pipefail
cd "$(dirname "$0")/.."
test "$PWD" = /private/tmp/vesta-home-verify/VestaHome || { echo "Use the canonical Home build path." >&2; exit 1; }
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to the pinned Xcode}"
HAVE=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$DEVELOPER_DIR/../version.plist")
test "$HAVE" = "$(cat .xcode-build-version)" || { echo "Xcode build does not match .xcode-build-version." >&2; exit 1; }
unset VESTA_CLASSIC
export VESTA_MACOS_TARGET=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' home/Info.plist)
swift build -c release --product VestaHome --arch arm64 --arch x86_64 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$PWD/home/Info.plist"
BIN=.build/apple/Products/Release/VestaHome
lipo "$BIN" -verify_arch arm64 x86_64
