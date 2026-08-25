# BLE spike findings — 2026-08-15

Run: `./bundle.sh && open -W build/HueScan.app --args 25`

## Hardware present

Two Philips Hue bulbs, both with strong signal (well within BLE range):

| Name | Model | Firmware | RSSI | Peripheral UUID |
|---|---|---|---|---|
| Desk lamp | LCB002 | 1.163.1 | −45 | `11111111-1111-4111-8111-111111111111` |
| Corner lamp | LCB002 | 1.163.1 | −48 | `22222222-2222-4222-8222-222222222222` |

Manufacturer reads back as `Signify Netherlands B.V.`. LCB002 is a colour + tunable-white
A19/E26 bulb, so both colour (xy) and colour temperature (mireds) are in scope.

No Hue Bridge on the local network (`dns-sd -B _hue._tcp` found nothing), so
Bluetooth is the only transport available. There is no bridge fallback to lean on.

## Protocol surface confirmed

Both bulbs advertise service `FE0F` (Philips Hue) and expose the proprietary control
service `932C32BD-0000-47A2-835A-A8D455B859DD` with exactly the characteristics the
community reverse-engineering describes:

| Characteristic | Props | Meaning |
|---|---|---|
| `932C32BD-0001-…` | read | (identity / metadata) |
| `932C32BD-0002-…` | read, write, notify | **on/off** — 1 byte, 0x00/0x01 |
| `932C32BD-0003-…` | read, write, notify | **brightness** — 1 byte, 1–254 |
| `932C32BD-0004-…` | read, write, notify | **colour temperature** — uint16 LE, mireds |
| `932C32BD-0005-…` | read, write, notify | **colour** — CIE xy, 2× uint16 LE |
| `932C32BD-0007-…` | read, write, notify | (scene/effect) |

The characteristics all support `notify`, which matters for UX: the app can reflect
changes made from the Hue app or a physical switch instead of guessing.

Device Information (`180A`) reads **without** authentication — manufacturer, model,
firmware. Useful for identifying bulbs before we are paired.

## The blocker: every control characteristic requires bonding

Every read against the control service returned:

```
Authentication is insufficient.
```

`97FE6561-0003-…` returned `Encryption is insufficient.` The bulbs will not accept
reads or writes over an unauthenticated link. This is expected — Hue requires a BLE
bond — but **macOS did not present a pairing dialog** when CoreBluetooth hit the
error. It surfaced the error to the app instead.

Two plausible reasons, in order of likelihood:

1. **The spike runs as a background agent** (`LSUIElement`, launched via `open`). It
   has no foreground UI, so the system pairing prompt may be suppressed or presented
   somewhere invisible.
2. **The bulbs are not in pairing mode.** Hue bulbs only accept a *new* bond during a
   window after power-on/reset, or when released by the Hue app. An already-bonded
   bulb refuses new pairings.

This is the single highest-risk unknown in the project and everything else depends on
it. Resolving it is the next step, before any app architecture is committed to.

## Toolchain notes (cost real time, worth recording)

- Xcode was not installed; only Command Line Tools. SwiftPM's default `swiftbuild`
  backend fails with "Could not initialize build system"; `--build-system native`
  works. Xcode is being installed, which should remove this constraint.
- CoreBluetooth hard-aborts (SIGABRT, TCC namespace) without
  `NSBluetoothAlwaysUsageDescription`. For a binary run straight from a shell, the
  bundle's `Contents/Info.plist` is **not** consulted — the plist must be embedded in
  the Mach-O via `-sectcreate __TEXT __info_plist`.
- Even with the plist embedded, a shell-exec'd binary is attributed by TCC to its
  *parent* process. It must be launched through LaunchServices (`open`) to be its own
  responsible process — which detaches stdout, hence the file-based logging.
