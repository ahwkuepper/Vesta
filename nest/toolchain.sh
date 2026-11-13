#!/bin/bash
# Full Xcode supplies Swift Testing. Respect an explicit toolchain selection.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
