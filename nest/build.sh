#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
source ./toolchain.sh
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
DEST="$ROOT/.build/nest-reader"
mkdir -p "$DEST"
IDENTITY="${VESTA_SIGNING_IDENTITY:-Vesta Development}"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
    echo "A stable signing identity is required for persistent Keychain access." >&2
    echo "Use tools/make-signing-identity.sh or set VESTA_SIGNING_IDENTITY." >&2
    exit 1
fi
cp "$BIN_DIR/nest-reader" "$DEST/nest-reader.new"
codesign --force --sign "$IDENTITY" --identifier io.github.ahwkuepper.NestReader \
    --options runtime --timestamp=none "$DEST/nest-reader.new"
codesign --verify --strict "$DEST/nest-reader.new"
mv "$DEST/nest-reader.new" "$DEST/nest-reader"
echo "Built: $DEST/nest-reader"
