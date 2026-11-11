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

# Comment lines are stripped before every content check. A check that fires on prose
# gets disabled, and a disabled check protects nothing.
without_comments() {
    grep -v "^[^:]*:[0-9]*:[[:space:]]*//" \
        | grep -v "^[^:]*:[0-9]*:[[:space:]]*\*" \
        | grep -v "^[^:]*:[0-9]*:[[:space:]]*/\*"
}

echo "== no third-party dependencies =="
if grep -q '\.package(url:' Package.swift; then
    note "Package.swift declares a remote package"
elif grep -q 'binaryTarget' Package.swift; then
    # A remote XCFramework is a dependency that never appears as a package: it is
    # precompiled, unauditable, and links straight into a binary holding Bluetooth,
    # network and Keychain access.
    note "Package.swift declares a binaryTarget"
elif [ -f Package.resolved ]; then
    note "Package.resolved exists, so something resolved a remote package"
else
    echo "  ok — Apple frameworks only"
fi

echo "== network access confined to declared transports =="
# Every outbound call must go through a transport module that has been reviewed for
# it. A device module quietly opening its own URLSession is exactly how "fully local"
# stops being true.
allowed="Sources/(VestaBridge|KasaTransport)/"
# Comment lines are stripped first: a check that fires on prose gets disabled, and
# a disabled check protects nothing.
# Beyond the obvious Foundation and Network types: a raw BSD socket, a shell-out to
# curl, or Data(contentsOf:) over a URL are all egress that the framework names miss.
# `connect(`/`bind(` alone are too generic — CoreBluetooth has its own connect() —
# and a raw BSD socket is unusable without socket(), which is listed.
egress="URLSession|NWConnection|NWBrowser|NWListener|CFStream|CFSocket|[^A-Za-z]socket\\(|Process\\(|NSTask|posix_spawn|execv|Data\\(contentsOf:"
offenders=$(grep -rnE "$egress" Sources/ \
    | without_comments \
    | cut -d: -f1 | sort -u | grep -vE "^$allowed" || true)
if [ -n "$offenders" ]; then
    for f in $offenders; do note "network API used outside a transport module: $f"; done
else
    echo "  ok — only $allowed"
fi

echo "== module layering =="
# The split into targets is only worth having if it cannot quietly collapse. The
# domain must not know about any transport or any interface, and the command line
# must not depend on the interface — that dependency is what put a 568-line CLI and
# a 405-line renderer inside the app target in the first place.
layering_ok=1
forbid_import() {  # $1 = target dir, $2 = module it must not import, $3 = why
    if grep -rn "^import $2\b" "Sources/$1" >/dev/null 2>&1; then
        note "Sources/$1 imports $2 — $3"
        layering_ok=0
    fi
}
for forbidden in VestaBLE VestaBridge VestaUI VestaDesign VestaCLI VestaDiagnostics KasaTransport KasaUI AppKit SwiftUI; do
    forbid_import VestaKit "$forbidden" "the domain must stay independent of protocol and interface"
done
for forbidden in KasaTransport KasaUI AppKit SwiftUI; do
    forbid_import KasaKit "$forbidden" "the Kasa domain must stay independent of its transport and interface"
done
for forbidden in KasaUI VestaUI VestaCLI; do
    forbid_import KasaTransport "$forbidden" "a transport must not depend on its callers"
done
for forbidden in VestaBLE VestaBridge KasaTransport KasaUI VestaUI VestaCLI; do
    forbid_import VestaDesign "$forbidden" "shared visual components must not depend on devices or app lifecycle"
done
forbid_import VestaCLI VestaUI "the command line must not depend on the interface"
for forbidden in VestaBridge VestaBLE KasaTransport NestCore; do
    forbid_import HomePreviewUI "$forbidden" "the layout preview must use sample data only"
done
forbid_import VestaDiagnostics VestaUI "the report is shared by the interface and the CLI"
for forbidden in VestaUI VestaCLI; do
    forbid_import VestaBridge "$forbidden" "a transport must not depend on its callers"
    forbid_import VestaBLE "$forbidden" "a transport must not depend on its callers"
done
if [ $layering_ok -eq 1 ]; then
    echo "  ok — domain, transports, CLI and interface stay in their layers"
fi

echo "== no runtime code loading =="
# A loaded bundle inherits the app's entitlements, sandbox and Keychain access.
# Device modules are compile-time targets that went through review, never plug-ins.
if grep -rnE "dlopen|dlsym|NSBundle\(path|Bundle\(path:|Bundle\(url:|Bundle\(identifier:|NSClassFromString" Sources/ \
   | without_comments | grep -q .; then
    note "dynamic code loading found — modules must be compiled in, not loaded"
else
    echo "  ok — no dynamic loading"
fi

echo "== no cleartext or third-party hosts =="
# Browser-link exceptions, enumerated rather than broadly pattern-matched: the UI hands
# these to the browser on an explicit click. Vesta makes no request, receives no
# response, and sends nothing — no version, no identifier, no timestamp. Any other
# host still fails the build.
ALLOWED_HOSTS='^https://github\.com/ahwkuepper/Vesta(/blob/main/home/SETUP.md)?$'
hosts=$(grep -rhoE 'https?://[a-zA-Z0-9./-]+' Sources/ \
        | sed 's|/releases$||' | sort -u | grep -vE "$ALLOWED_HOSTS" || true)
if [ -n "$hosts" ]; then
    for h in $hosts; do note "hard-coded host: $h"; done
else
    echo "  ok — local transports plus explicit browser documentation links"
fi

echo "== no force unwrapping of device input =="
# Responses come from devices on the LAN, which are untrusted input.
forced=$(grep -rn "try!\|as! " Sources/ | without_comments || true)
if [ -n "$forced" ]; then
    echo "$forced" | sed 's/^/    /'
    note "force unwrap in Sources"
else
    echo "  ok"
fi

echo "== standalone Nest cloud companion =="
if [ -d nest/Sources ]; then
    if grep -qE '\.package\(|binaryTarget' nest/Package.swift || [ -f nest/Package.resolved ]; then
        note "Nest must use Apple frameworks only"
    fi
    if grep -E 'NestCore|NestReader|nest/' Package.swift | grep -vE 'name: "(NestCore|HomeUI|HomeTests)"' | grep -q .; then
        note "the local-only applications must not link the cloud companion"
    fi
    nest_egress=$(grep -rnE "$egress" nest/Sources/ | without_comments \
        | cut -d: -f1 | sort -u | grep -v '^nest/Sources/NestCore/Transport.swift$' || true)
    if [ -n "$nest_egress" ]; then note "Nest network APIs used outside Transport.swift: $nest_egress"; fi
    nest_hosts=$(grep -rhoE 'https?://[a-zA-Z0-9./-]+' nest/Sources/ | sort -u \
        | grep -vE '^https://(oauth2.googleapis.com/token|smartdevicemanagement.googleapis.com/v1/|smartdevicemanagement.googleapis.com/v1/enterprises/|www.google.com|www.googleapis.com/auth/sdm.service)$' || true)
    if [ -n "$nest_hosts" ]; then note "unexpected Nest endpoint: $nest_hosts"; fi
    if grep -rnE 'try!|as! |dlopen|dlsym|NSClassFromString' nest/Sources/ | without_comments | grep -q .; then
        note "unsafe decoding or runtime loading in Nest"
    fi
    echo "  checked — separate package, Google endpoint allowlist, scoped transport"
fi

echo
[ $fail -eq 0 ] && echo "boundaries intact" || echo "BOUNDARY VIOLATIONS — see above"
exit $fail
