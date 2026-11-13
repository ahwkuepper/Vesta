#!/bin/bash
# Check the complete publication candidate, including untracked source files.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 tools/check_public_tree.py "$@"
