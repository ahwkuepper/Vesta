#!/bin/bash
# Undo tools/make-signing-identity.sh.
#
# That script installs a TRUSTED CODE-SIGNING ROOT in your login keychain, not just
# a key. Nothing removed Vesta's certificate when you deleted the app, and a trusted
# signing root is a durable privilege. This removes it.
set -euo pipefail

NAME="${1:-Vesta Development}"
echo "Removing the '$NAME' signing identity and its trust setting."

security find-certificate -c "$NAME" -a -Z 2>/dev/null \
  | awk '/SHA-256 hash:/ {print $3}' \
  | while read -r sha; do
        security delete-certificate -Z "$sha" 2>/dev/null \
            && echo "  removed certificate $sha" \
            || echo "  could not remove $sha (it may need your keychain password)"
    done

echo
echo "Verify with:  security dump-trust-settings | grep -A2 '$NAME'"
echo "Nothing should be listed."
