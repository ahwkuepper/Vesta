#!/bin/bash
# Build the separate Kasa app; no Python runtime or external packages are needed.
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo "Use debug or release" >&2; exit 1 ;; esac
# The deployment target and linked SDK are different facts. Explicitly stamp the
# SDK used for this build: the Xcode SwiftPM backend otherwise stamped 14.0 in the
# first Kasa binary even though it compiled against the 27.0 SDK. That opts native
# AppKit/SwiftUI controls into compatibility appearance on a modern macOS.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
MIN_OS="${VESTA_MACOS_TARGET:-14.0}"
if [ "${SDK_VERSION%%.*}" -lt 26 ]; then
    echo "error: Vesta Kasa needs an Xcode with macOS SDK 26 or newer." >&2
    exit 1
fi
swift build -c "$CONFIG" --product VestaKasa \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/kasa/Info.plist"
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)
BUILT="$BIN_DIR/VestaKasa"
LINKED_SDK=$(otool -l "$BUILT" | awk '$1 == "sdk" {print $2; exit}')
if [ "${LINKED_SDK%%.*}" != "${SDK_VERSION%%.*}" ]; then
    echo "error: built executable reports SDK $LINKED_SDK; expected $SDK_VERSION." >&2
    exit 1
fi
APP="$PWD/.build/kasa-app/Vesta Kasa.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/VestaKasa"
cp kasa/Info.plist "$APP/Contents/Info.plist"
IDENTITY="${VESTA_SIGNING_IDENTITY:-Vesta Development}"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
    IDENTITY="-"
    echo "Using ad-hoc signing; a rebuild may prompt for Keychain access again."
fi
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.VestaKasa \
    --options runtime --timestamp=none --entitlements kasa/entitlements.plist "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
