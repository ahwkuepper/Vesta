#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ./toolchain.sh
swift test "$@"
