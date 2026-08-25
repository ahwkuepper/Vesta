#!/bin/bash
# Build Lumo.app.
#
# The Info.plist is both embedded in the Mach-O (via -sectcreate) and copied into
# the bundle: TCC reads the embedded copy, which is what CoreBluetooth's usage
# description must come from, while LaunchServices reads the bundle copy.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

CONFIG="${1:-release}"

# SwiftUI's @State / @Bindable are macros, and the SwiftUIMacros plugin that
# expands them ships inside Xcode — Command Line Tools alone cannot build this.
# DEVELOPER_DIR selects a toolchain without needing sudo xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
if [ -z "${DEVELOPER_DIR:-}" ]; then
    echo "error: Xcode not found. Lumo needs Xcode for the SwiftUI macro plugin." >&2
    exit 1
fi
echo "[toolchain] $DEVELOPER_DIR"

swift build -c "$CONFIG" --product Lumo \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Info.plist"

APP="build/Lumo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Lumo" "$APP/Contents/MacOS/Lumo"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists. Ad-hoc signatures change hash on
# every rebuild, which makes the sandbox look like a different app each time and
# re-prompts for keychain access to the bridge key. Create one with
# ./tools/make-signing-identity.sh.
IDENTITY="Lumo Development"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "[codesign] no '$IDENTITY' identity — falling back to ad-hoc (expect keychain prompts)"
    IDENTITY="-"
fi

codesign --force --sign "$IDENTITY" --identifier dev.lumo.Lumo \
    --entitlements entitlements.plist "$APP" 2>&1 | sed 's/^/[codesign] /'

# Also sign the un-bundled binary with the same identity and identifier. Keychain
# ACLs match a signed app by its designated requirement (certificate + identifier),
# not by hash, so the CLI shares the app's keychain access — and being outside the
# sandbox it can write logs to ordinary paths, which the protected app container
# no longer allows.
codesign --force --sign "$IDENTITY" --identifier dev.lumo.Lumo \
    ".build/$CONFIG/Lumo" 2>&1 | sed 's/^/[codesign cli] /'

echo "built: $ROOT/$APP"
