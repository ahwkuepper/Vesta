# Roadmap

Planned work and the findings behind it. Nothing here is committed.

## Bridge resources not yet used

Probed against a bridge with four lights (`--dump <type>`).

| Resource | Count | Possible use |
|---|---|---|
| `behavior_script` | 14 | Automation catalogue the bridge runs itself |
| `behavior_instance` | 1 | Configured automations and their run state |
| `entertainment` / `entertainment_configuration` | 5 / 1 | Low-latency streaming; screen or music sync |
| `zigbee_device_discovery` | 1 | Add a bulb from Vesta instead of the Hue app |
| `device_software_update` | 4 | Surface firmware updates per device |
| `zigbee_connectivity` | 5 | Link quality — a better "unreachable" than a failed write |
| `geolocation` | 1 | Sunset/sunrise. `is_configured` was false |
| `homekit` / `matter` | 1 / 1 | What else controls these lights |
| `grouped_light` | 3 | Already used for room switching |
| `button`, `motion`, `contact`, `temperature`, `light_level` | 0 | Sensors — none on this setup |

Available `behavior_script` templates: Schedule, Timers (countdown), Basic wake up
routine, Go to sleep routines, Native Go To Sleep, Coming home, Leaving home, Motion
Sensor, Contact Sensor, Tap Switch, Hue Accessories, Smoke alarm, Light state after
streaming.

## Schedules

Schedules belong on the bridge, not in Vesta. A Mac sleeps and leaves the house; a
schedule in a menu-bar app fires only while the app runs. The bridge runs
continuously and has native scheduling via `behavior_instance`, including
sunset/sunrise, which also handles DST and timezones.

Vesta's role is to edit schedules that execute elsewhere. Open questions: how to
represent behaviour instances in the UI, and what to offer for backends with no
scheduling of their own. Sunset/sunrise requires `geolocation` to be configured
first, so that belongs in the setup flow.

## iOS

`VestaKit` is pure domain logic and `VestaBridge` is `URLSession`; both should compile
for iOS unchanged. `VestaBLE` uses CoreBluetooth, which exists on iOS. The work is a
new UI layer — a widget and a Control Centre control rather than a menu bar — plus
iOS's local-network permission prompt. `Package.swift` gains iOS platforms and the
app targets separate.

## Kasa (TP-Link)

Probed with a UDP broadcast on port 9999. Four devices answered with no credential.

| Device | Model | Capability |
|---|---|---|
| 3 plugs | HS105 | on/off only |
| 1 bulb | KL110 | dimmable; no colour, no variable colour temperature |

Protocol: JSON over TCP 9999 with a 4-byte length prefix, UDP for discovery,
obfuscated with an autokey XOR starting at 171. LAN-only, so it fits the no-internet
rule. Newer firmware uses KLAP with a handshake; a module must handle both and prefer
the authenticated path.

Security findings that constrain the UI:

- **No authentication.** Anyone on the network can enumerate and control these
  devices. Vesta must not present them as protected the way a pinned Hue connection
  is.
- **The plugs disclose the home's location.** `latitude_i` and `longitude_i` return
  real coordinates, unauthenticated, along with `deviceId`, `oemId` and MAC. These
  must never reach a log or a diagnostics report, and the UI should say the devices
  leak them.

This range — three switchable plugs and one brightness-only bulb — is the argument
for a capability-driven UI. The row that shows temperature, gradient and effects for
a Play lamp must collapse to a single switch for an HS105. `LightCapabilities`
already models this.

## Devices instead of modes

"Bridge" and "Bluetooth" currently appear in the UI as modes, which leaks an
implementation detail. Transport should be a property of a device, with a setup
wizard that scans the installed backends and adds what it finds. `LightTransport` is
already the right seam; the change is that the store aggregates several transports
at once rather than switching between them.

## Modular device stack

End state: `VestaKit` defines the device contract and each backend is its own target
— `VestaHue`, `VestaKasa`, `VestaMatter`. Adding a brand means adding a target and a
registration, not touching the UI.

A device module is arbitrary code holding the app's entitlements and Keychain
access. The prerequisites in [SECURITY.md](SECURITY.md) — egress choke point,
declared capabilities, scoped credentials, per-module authentication statement —
must exist before the first outside module, not after.

## Design

Liquid Glass is adopted via the deployment target, but nothing has been designed for
it specifically. Worth a pass over scene chips at rest and pressed, slider tracks
against a translucent ground, the active-scene indicator, and the expanded panel's
edges. Explicit `glassEffect` is invisible at chip and panel scale over a popover
that is already a system material; the leverage is in spacing, contrast and
hierarchy.
