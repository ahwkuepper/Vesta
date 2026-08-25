# Roadmap

Ideas worth doing, with what is already known about each. Nothing here is committed
work; it is the state of thinking so the next session does not start from scratch.

## Design detail in Liquid Glass

Liquid Glass is easy to adopt and hard to make beautiful. The adoption is done — the
macOS 26 build gets it from the deployment target — but nothing has been *designed*
for it. Worth a pass over: the scene chips at rest and pressed, slider tracks against
a translucent ground, how the active-scene tick reads on glass, and the expanded
control panel's edges. Note that explicit `glassEffect` proved invisible at chip and
panel scale; the leverage is in spacing, contrast and hierarchy, not in more glass.

## What the Hue Bridge actually exposes

Probed against a real bridge (`--dump <type>`); counts are from a four-light setup.

| Resource | Seen | What it would let Lumo do |
|---|---|---|
| `behavior_script` | 14 | The automation catalogue — see below |
| `behavior_instance` | 1 | Automations actually configured, and their run state |
| `entertainment` / `entertainment_configuration` | 5 / 1 | Low-latency streaming to lights; screen or music sync |
| `zigbee_device_discovery` | 1 | Adding a new bulb from Lumo, instead of the Hue app |
| `device_software_update` | 4 | Surface firmware updates per device |
| `zigbee_connectivity` | 5 | Real link quality — a better "unreachable" than a failed write |
| `geolocation` | 1 | Sunset/sunrise, **but `is_configured` was false** |
| `homekit` / `matter` | 1 / 1 | What else already controls these lights |
| `grouped_light` | 3 | Already used for room switching |
| `button`, `motion`, `contact`, `temperature`, `light_level` | 0 | Sensors — none on this setup, but the model should not assume lights only |

The catalogue (`behavior_script`) is the interesting part, because the bridge runs
these itself:

- **Schedule** — "Schedule turning on and off lights"
- **Timers** — "Countdown Timer"
- **Basic wake up routine**, **Go to sleep routines**, **Native Go To Sleep**
- **Coming home** / **Leaving home** — geofence-driven
- **Motion Sensor**, **Contact Sensor**, **Tap Switch**, **Hue Accessories**
- **Smoke alarm**, **Light state after streaming**

Two consequences. Lumo can offer real scheduling by creating `behavior_instance`
resources from these scripts, with no daemon of its own. And **sunset/sunrise needs
`geolocation` configured first** — it is not set on this bridge, so that has to be
part of the setup flow rather than assumed.

## Timers and schedules

The important decision comes first: **schedules belong on the bridge, not in Lumo.**
A Mac sleeps, gets closed, and goes out of the house. A schedule that lives in a
menu-bar app fires only when the app is running, which is exactly not what "turn the
lights on at sunset" means. The bridge runs continuously and already has native
scheduling (`behavior_instance`), including sunset/sunrise, which also solves DST and
timezone correctness for free.

So Lumo's job is to be a good editor for schedules that execute elsewhere. Two things
to work out: how to represent bridge behaviour instances in the UI, and what to do
for backends with no scheduling of their own — probably "this device cannot be
scheduled" rather than a half-working local timer that lies when the lid is shut.

## iOS version

The split already helps: `LumoKit` is pure domain logic and `LumoBridge` is
`URLSession` — both should compile for iOS unchanged. `LumoBLE` uses CoreBluetooth,
which exists on iOS. The work is a new UI layer (no menu bar; a widget and Control
Centre control are the natural equivalents) plus iOS's own local-network permission
prompt. `Package.swift` would gain iOS platforms and the app targets would separate.

## Kasa (TP-Link) lamps and plugs

Probed on a real network with a UDP broadcast on port 9999. Four devices answered
**with no credential of any kind**:

| Device | Model | Capability |
|---|---|---|
| plug A | HS105 | on/off only |
| plug B | HS105 | on/off only |
| plug C | HS105 | on/off only |
| bulb | KL110 | `is_dimmable: 1`, `is_color: 0`, `is_variable_color_temp: 0` |

So the option space is real but narrow: three switchable plugs and one
brightness-only bulb reporting `{"on_off": 0, ... "brightness": 69}`. This is the
strongest argument for a capability-driven UI — the same row that shows temperature,
gradient and effects for a Play lamp must collapse to a single switch for an HS105,
which the existing `LightCapabilities` already models.

Integration is straightforward: the protocol is JSON over TCP 9999 (4-byte length
prefix) or UDP for discovery, obfuscated with an autokey XOR starting at 171. It is
LAN-only, so it fits the no-internet rule.

**The security findings are the important part, and they change what the UI may
claim:**

- **There is no authentication.** Anyone on the network can enumerate and control
  these devices. Lumo cannot fix this, and must not present these devices as
  protected in the way Hue's pinned-certificate connection is.
- **The plugs broadcast the home's location.** `latitude_i` and `longitude_i` come
  back populated with real coordinates, unauthenticated, to anyone on the LAN, along
  with `deviceId`, `oemId` and MAC. (Values are not reproduced here for the obvious
  reason.) Lumo must never log or include these in a diagnostics report, and should
  say plainly that these devices leak them.
- Newer firmware uses KLAP with a handshake; a module must handle both and should
  prefer the authenticated one where available.

## One device model, many backends

Right now "Bridge" and "Bluetooth" appear in the UI as modes, which is an
implementation detail leaking into the interface. Nobody thinks "I want to control my
Bluetooth lamp"; they think "I want to turn on the lamp". The transport should be a
property of a device, not a mode the user selects — with a setup wizard that scans
whatever backends are installed and adds what it finds. `LightTransport` is already
the right seam; what changes is that the store aggregates *several* transports at
once instead of switching between them.

## A modular device stack

The end state: `LumoKit` defines the device contract, and each backend is a separate
target — `LumoHue`, `LumoKasa`, `LumoMatter` — with a clear place for brand, protocol
and device type. Adding a brand should mean adding a target and a registration, not
touching the UI.

This is also where the security work becomes load-bearing: a device module is
arbitrary code with the app's entitlements and its Keychain. See
[SECURITY.md](SECURITY.md) — the egress choke point, declared capabilities, scoped
credentials and a per-module authentication statement all need to exist *before* the
first outside module, not after.
