# Vesta Kasa

A separate macOS menu-bar app for Kasa plugs and bulbs, using Vesta's interface.
It discovers devices on your Wi-Fi, shows bulbs and plugs together, and provides
individual power switches and capability-dependent brightness and colour controls.
There is no dependency on Python, Home Assistant, or a cloud service.

The two apps share `VestaDesign`: typography, header metrics, row surfaces,
colour swatches, native gradient sliders, and Liquid Glass preset chips. The
popover uses the system material. Both menus are 330 points wide; their height
follows their content and scrolls only when it exceeds the available screen.
The host measures the space below its menu-bar icon before opening, using that
icon's display. The complete page is capped, including sign-in and error messages;
the header stays visible and the body scrolls. Reopening after a display change
remeasures that space instead of reusing the previous popover size.
A reconnect keeps known controls in place, so refreshing does not collapse rows.

Build with Xcode and a macOS 26 or newer SDK installed:

```sh
./build-kasa.sh
open '.build/kasa-app/Vesta Kasa.app'
```

Allow Local Network access when macOS asks. Newer devices appear with a sign-in
prompt. Use the same email and password as the Kasa app. The app verifies the
credentials against a local device, then saves only the account-derived KLAP keys
in its own Keychain service. The keys still grant device access; signing out deletes
them. The original email and password are not saved. If authentication fails, check
**Me → Settings → Third-Party Compatibility** in the Kasa app.

Device names and last known addresses are cached in the app's sandboxed preferences.
Cached devices start unavailable until read successfully. Status is refreshed every
ten seconds; discovery repeats every minute and can also be triggered manually.
The header switch controls bulbs; each plug is switched individually. Power and colour controls leave existing schedules alone. Time zones and
locations are never modified by this app.

The app can run alongside Vesta for Hue. It has a separate bundle identifier,
Keychain service, preferences, and single-instance lock. **Open at login** is
available in its settings menu; place the app at its permanent location first.

## Schedules

Click the clock beside any bulb or plug to open its schedules inline. Existing
rules can be enabled, edited or deleted; **Add schedule** creates a new rule.
The editor supports on/off actions, optional bulb brightness, clock times,
sunrise/sunset with minute offsets, weekly repeat days, and one-time dates.
Changes in the editor are sent only when you press **Save**. Rule switches and the
schedules master switch apply immediately; deletion asks for confirmation.

Schedules are stored and executed by the device, including while the Mac is asleep.
Times and dates use the device's wall clock, not a conversion from the Mac's zone.
The panel shows the device time at the last refresh and warns if that sample differs
from the Mac by more than five minutes. Sunrise/sunset uses the location already
configured in Kasa. Correct the location/time zone in the Kasa app if needed.

Edits preserve saved colour, transition and unknown firmware fields. A fresh read
before a write detects conflicting edits from another app; a read after the write
checks the result. A lost reply is not replayed automatically. Refresh and review
the schedules before retrying an uncertain change, especially an addition.
Advanced rules the editor cannot represent remain visible and can be disabled;
edit those in Kasa. New rules do not automatically unpause the schedule module.

The schedule protocol uses the existing local transport and credentials. This
change touches Constitution articles 4, 6 and 7: bounded decoding, anonymous
read-only diagnostics, and explicit errors for unsupported or uncertain operations.
The wire formats were checked against the upstream
[tplink-smarthome-api schedule implementation](https://github.com/plasticrake/tplink-smarthome-api/blob/master/src/shared/schedule.ts)
and read-only responses from all eight devices on the development LAN. No live
schedule was changed during verification; mutation handling is covered by synthetic
tests, including field preservation, conflicts, outlet scope and read-back checks.

## Supported connections

- Legacy Kasa IOT plugs, bulbs, dimmers, and power-strip outlets using XOR over TCP 9999.
- Kasa IOT devices using KLAP v1 or v2 over HTTP port 80, including the KL110 and EP10
  hardware/firmware variants inspected during development.
- Colour and temperature controls appear only when advertised by the bulb. The
  current temperature control covers 2500–6500 K.
- New SMART/Tapo, AES, HTTPS-only, and other protocols appear as unsupported. This
  app does not claim support for every TP-Link product.
- Discovery is IPv4 broadcast on the same LAN. Routed VLANs and remote access are
  not supported.

## Transport and credential review

This addition is security-relevant under Constitution articles 1–7.
`KasaTransport` is the only new module allowed to open sockets or HTTP sessions.
It uses Apple's Foundation, CryptoKit, CommonCrypto, Security, and BSD interfaces.
No external packages, scripts, or runtime plug-ins are bundled.

Discovery sends UDP probes on 9999 and 20002 and receives replies on a temporary
bound socket. Thus the app needs sandbox network client and server entitlements;
there is no persistent listening server. Destinations must be numeric private IPv4
addresses within a directly connected active subnet. Addresses advertised in device
payloads are ignored in favour of packet source addresses. HTTP redirects, shared
cookies, credential storage and proxies are disabled. The HTTP ATS exception is
needed for numeric local device endpoints; the transport enforces destination scope.

Legacy XOR provides neither secrecy nor device authentication. KLAP verifies a
server proof of the account-derived key, uses fresh session seeds, and checks
response signatures. This proves possession of the account key, not a unique bulb
identity or manufacturer certificate. Neither protocol is presented as a pinned
identity. Requests and responses have size limits and deadlines. A failed command
is read back rather than replayed automatically.

Protocol interoperability was informed by the published
[python-kasa protocol documentation](https://python-kasa.readthedocs.io/en/latest/topics.html).
The Swift implementation uses Apple crypto primitives; the Python package is not
included. Synthetic test vectors are cross-checked with python-kasa.

## Validation

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./tools/check-boundaries.sh
./tools/check-no-secrets.sh
.build/debug/VestaKasa --discover
.build/debug/VestaKasa --snapshot /tmp/kasa-preview
.build/debug/VestaKasa --snapshot-schedules /tmp/kasa-schedule-preview
# Run the signed app binary to use its existing Keychain access:
'/Applications/Vesta Kasa.app/Contents/MacOS/VestaKasa' --check-schedules
VESTA_CLASSIC=1 ./build-kasa.sh debug
```

The build explicitly records the selected SDK in the executable and verifies it
before signing. This matters independently of the macOS 14 deployment target:
an executable stamped with an old SDK uses compatibility appearances for native
controls. `VESTA_CLASSIC=1` exercises the fallback custom-chip rendering.

`--discover` is read-only and prints model/protocol/counts, not names, addresses or
credentials. `--snapshot` uses synthetic devices and does not access the network or
Keychain. `--snapshot-schedules` renders synthetic schedule views.
`--check-schedules` reads the real devices using the existing Keychain credentials
and reports model names, rule counts and clock agreement; it performs no writes.
