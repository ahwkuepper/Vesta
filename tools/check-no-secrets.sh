#!/bin/bash
# Catches real identifiers before they reach a public repo.
#
# This exists because it happened twice in one day: a bridge ID derived from a MAC
# address, and then a home's latitude and longitude, both written into files destined
# to be published. Prose is written in the moment; a check does not forget.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# Real values look like this. Documentation values are RFC 5737 TEST-NET ranges,
# and synthetic IDs use the aabbcc… placeholder.
patterns=(
  '192\.168\.[0-9]'          # private LAN, excluding the doc ranges below
  '10\.[0-9]+\.[0-9]+\.[0-9]+'
  '172\.(1[6-9]|2[0-9]|3[01])\.'
  '[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}'  # MAC
  'latitude_i"?[: ]+-?[0-9]{4,}'
  'longitude_i"?[: ]+-?[0-9]{4,}'
)
targets=$(git ls-files '*.md' '*.swift' '*.sh' '*.yml' '*.plist' 2>/dev/null)

for pattern in "${patterns[@]}"; do
    hits=$(echo "$targets" | xargs grep -nEi "$pattern" 2>/dev/null \
        | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' \
        | grep -vE 'aa:bb:cc' || true)
    if [ -n "$hits" ]; then
        echo "  ✗ possible real identifier:"
        echo "$hits" | sed 's/^/      /'
        fail=1
    fi
done

if [ $fail -eq 0 ]; then
    echo "  ok — no real addresses, MACs or coordinates in tracked text"
else
    echo
    echo "Use RFC 5737 documentation addresses (192.0.2.x, 198.51.100.x, 203.0.113.x)"
    echo "and synthetic identifiers. Real values belong in nobody's repository."
fi
exit $fail
