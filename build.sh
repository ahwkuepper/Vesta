#!/bin/bash
# Build Vesta.app.
#
# The Info.plist is both embedded in the Mach-O (via -sectcreate) and copied into
# the bundle: TCC reads the embedded copy, which is what CoreBluetooth's usage
# description must come from, while LaunchServices reads the bundle copy.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

CONFIG="${1:-release}"

# Release mode: for anything that gets signed with a Developer ID and handed to
# someone else. It pins the toolchain, builds universal, and refuses to fall back
# to an ad-hoc signature.
RELEASE=0
[ "${2:-}" = "--release" ] && RELEASE=1

# SwiftUI's @State / @Bindable are macros, and the SwiftUIMacros plugin that
# expands them ships inside Xcode — Command Line Tools alone cannot build this.
# DEVELOPER_DIR selects a toolchain without needing sudo xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ "$RELEASE" = "1" ]; then
        echo "error: --release requires DEVELOPER_DIR to be set explicitly." >&2
        echo "       A release must not depend on which Xcode happens to be installed." >&2
        exit 1
    fi
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
if [ -z "${DEVELOPER_DIR:-}" ]; then
    echo "error: Xcode not found. Vesta needs Xcode for the SwiftUI macro plugin." >&2
    exit 1
fi

XCODE_BUILD=$(defaults read "$(dirname "$(dirname "$DEVELOPER_DIR")")/Contents/version" \
    ProductBuildVersion 2>/dev/null || echo unknown)
echo "[toolchain] $DEVELOPER_DIR ($XCODE_BUILD)"

# A published binary must not be built against a pre-release SDK: beta toolchains
# behave differently from released ones, and Apple's pre-release terms are not a
# basis on which to ship to strangers.
if [ "$RELEASE" = "1" ]; then
    PINNED=$(cat "$ROOT/.xcode-build-version" 2>/dev/null || echo "")
    case "$DEVELOPER_DIR" in
        *Xcode-beta*) echo "error: refusing to build a release with a beta Xcode." >&2; exit 1 ;;
    esac
    if [ -n "$PINNED" ] && [ "$XCODE_BUILD" != "$PINNED" ]; then
        echo "error: release pins Xcode $PINNED; this is $XCODE_BUILD." >&2
        echo "       The published hash is only reproducible on the pinned toolchain." >&2
        exit 1
    fi
fi

# Universal for a release: macOS 14 runs on Intel, and Rosetta translates x86_64 to
# arm64, not the reverse — an arm64-only build simply will not launch there.
ARCHS=""
[ "$RELEASE" = "1" ] && ARCHS="--arch arm64 --arch x86_64"

# shellcheck disable=SC2086
swift build -c "$CONFIG" --product Vesta $ARCHS \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Info.plist"

APP="build/Vesta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# A universal build writes the fat binary under .build/apple/Products; the
# .build/<config> symlink keeps pointing at the single-arch directory, so copying
# from it silently ships an arm64-only binary while the universal build succeeds
# beside it. That is exactly what happened once.
if [ "$RELEASE" = "1" ]; then
    CAP=$(printf '%s' "$CONFIG" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
    BUILT=".build/apple/Products/$CAP/Vesta"
else
    BUILT=".build/$CONFIG/Vesta"
fi
[ -f "$BUILT" ] || { echo "error: no binary at $BUILT" >&2; exit 1; }
cp "$BUILT" "$APP/Contents/MacOS/Vesta"

# Verify rather than assume: macOS 14 runs on Intel, and an arm64-only release
# simply will not launch there.
if [ "$RELEASE" = "1" ]; then
    if ! lipo -info "$APP/Contents/MacOS/Vesta" | grep -q x86_64; then
        echo "error: release binary is not universal — Intel Macs cannot run it." >&2
        lipo -info "$APP/Contents/MacOS/Vesta" >&2
        exit 1
    fi
    echo "[arch] $(lipo -info "$APP/Contents/MacOS/Vesta" | sed 's/.*: //')"
fi
# LSMinimumSystemVersion must match the variant actually built, or the classic
# build ships metadata claiming it needs macOS 26 and LaunchServices refuses to
# open it on the systems it was built for.
MIN_OS="${VESTA_MACOS_TARGET:-26.0}"
sed "s|<key>LSMinimumSystemVersion</key><string>[^<]*</string>|<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>|" \
    Info.plist > "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists. Ad-hoc signatures change hash on
# every rebuild, which makes the sandbox look like a different app each time and
# re-prompts for keychain access to the bridge key. Create one with
# ./tools/make-signing-identity.sh.
IDENTITY="${VESTA_SIGNING_IDENTITY:-Vesta Development}"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    if [ "$RELEASE" = "1" ]; then
        # Failing open to ad-hoc here would produce an unsigned artefact from a
        # locked keychain and only be caught at notarisation, if at all.
        echo "error: signing identity '$IDENTITY' not found, and --release will not" >&2
        echo "       fall back to an ad-hoc signature." >&2
        exit 1
    fi
    echo "[codesign] no '$IDENTITY' identity — falling back to ad-hoc (expect keychain prompts)"
    IDENTITY="-"
fi

# --options runtime enables the hardened runtime: library validation, no
# unsigned-code injection, no DYLD environment overrides. It is also a
# prerequisite for notarisation. --timestamp is required for the same reason.
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.Vesta \
    --options runtime --timestamp \
    --entitlements entitlements.plist "$APP" 2>&1 | sed 's/^/[codesign] /'

# Also sign the un-bundled binary with the same identity and identifier. Keychain
# ACLs match a signed app by its designated requirement (certificate + identifier),
# not by hash, so the CLI shares the app's keychain access — and being outside the
# sandbox it can write logs to ordinary paths, which the protected app container
# no longer allows.
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.Vesta \
    --options runtime --timestamp \
    "$BUILT" 2>&1 | sed 's/^/[codesign cli] /'

echo "built: $ROOT/$APP"
