#!/bin/bash
# Enforces the structural security properties that are easy to state and easy to
# erode. Run in CI on every push and pull request.
#
# These are not style rules. Each one closes a path by which a well-meaning patch —
# or a malicious one — could turn a local-only app into one that talks to the
# internet, or could give a device module more reach than it needs.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
note() { echo "  ✗ $1"; fail=1; }

echo "== no third-party dependencies =="
if grep -q '\.package(url:' Package.swift; then
    note "Package.swift declares a remote package"
elif [ -f Package.resolved ]; then
    note "Package.resolved exists, so something resolved a remote package"
else
    echo "  ok — Apple frameworks only"
fi

echo "== network access confined to declared transports =="
# Every outbound call must go through a transport module that has been reviewed for
# it. A device module quietly opening its own URLSession is exactly how "fully local"
# stops being true.
allowed="Sources/LumoBridge/"
# Comment lines are stripped first: a check that fires on prose gets disabled, and
# a disabled check protects nothing.
offenders=$(grep -rn "URLSession\|NWConnection\|NWBrowser\|CFStream\|Socket" Sources/ \
    | grep -v "^[^:]*:[0-9]*:[[:space:]]*//" \
    | grep -v "^[^:]*:[0-9]*:[[:space:]]*\*" \
    | cut -d: -f1 | sort -u | grep -v "^$allowed" || true)
if [ -n "$offenders" ]; then
    for f in $offenders; do note "network API used outside a transport module: $f"; done
else
    echo "  ok — only $allowed"
fi

echo "== no runtime code loading =="
# A loaded bundle inherits the app's entitlements, sandbox and Keychain access.
# Device modules are compile-time targets that went through review, never plug-ins.
if grep -rn "dlopen\|NSBundle(path\|Bundle(path:\|NSClassFromString" Sources/ >/dev/null 2>&1; then
    note "dynamic code loading found — modules must be compiled in, not loaded"
else
    echo "  ok — no dynamic loading"
fi

echo "== no cleartext or third-party hosts =="
hosts=$(grep -rhoE 'https?://[a-zA-Z0-9.-]+' Sources/ | sort -u || true)
if [ -n "$hosts" ]; then
    for h in $hosts; do note "hard-coded host: $h"; done
else
    echo "  ok — every destination is a device the user paired with"
fi

echo "== no force unwrapping of device input =="
# Responses come from devices on the LAN, which are untrusted input.
if grep -rn "try!\|as! " Sources/ >/dev/null 2>&1; then
    grep -rn "try!\|as! " Sources/ | sed 's/^/    /'
    note "force unwrap in Sources"
else
    echo "  ok"
fi

echo
[ $fail -eq 0 ] && echo "boundaries intact" || echo "BOUNDARY VIOLATIONS — see above"
exit $fail
