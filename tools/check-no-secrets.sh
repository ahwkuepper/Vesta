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
  # A bridge ID is a MAC widened to EUI-64. It is the stable identifier for a
  # specific home, and it carries the vendor OUI.
  '[0-9a-f]{6}fffe[0-9a-f]{6}'
  # The mDNS name derived from that ID: the same identifier, one step removed.
  '[0-9a-f]{12}\.local'
  # IPv6, which the address patterns above never covered.
  '([0-9a-f]{1,4}:){4,}[0-9a-f]{0,4}'
)

# Every tracked text file, not a hand-maintained list of extensions. The recorded
# bridge fixtures are .json — the one file type whose whole purpose is holding real
# responses — and they were exempt from this check until they were named here.
targets=$(git ls-files | grep -vE '\.(png|jpg|jpeg|gif|pdf|zip|icns)$' 2>/dev/null)

for pattern in "${patterns[@]}"; do
    hits=$(echo "$targets" | xargs grep -nEi "$pattern" 2>/dev/null \
        | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' \
        | grep -viE 'aa:bb:cc|aabbccfffe112233|aabbcc112233\.local' \
        | grep -v 'check-no-secrets: allow' || true)
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
    echo
    echo "A literal that genuinely must be there — a test asserting private ranges are"
    echo "accepted — can carry a trailing  // check-no-secrets: allow  comment."
fi
exit $fail
