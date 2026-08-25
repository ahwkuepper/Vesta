#!/bin/bash
# Wrap the huescan executable in a minimal .app bundle.
#
# Two non-obvious requirements, both learned the hard way:
#  1. CoreBluetooth aborts the process (SIGABRT, TCC namespace) unless it can find
#     NSBluetoothAlwaysUsageDescription. When the binary is exec'd directly rather
#     than launched through LaunchServices, TCC does NOT read Contents/Info.plist —
#     the plist has to be embedded in the Mach-O as a __TEXT,__info_plist section.
#     We do both so the tool works either way.
#  2. --build-system native: the newer swiftbuild backend needs a full Xcode
#     install, and this machine only has Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

swift build -c release --build-system native --product huescan \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Info.plist"

APP="build/HueScan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/huescan "$APP/Contents/MacOS/HueScan"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - --identifier dev.lumo.huescan \
    --entitlements entitlements.plist "$APP" 2>&1 | sed 's/^/[codesign] /'

echo "built: $APP"
