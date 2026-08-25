# Lumo — a menu-bar controller for Philips Hue over Bluetooth

## What we know for certain (from the spike, not from assumption)

Two `LCB002` colour bulbs — "Desk lamp" and "Corner lamp" — are in range at
RSSI −45/−48. They expose the Hue control service `932C32BD-0000-…` with on/off,
brightness, colour-temperature and colour-xy characteristics, all supporting
`notify`. There is **no Hue Bridge** on the network, so BLE is the only transport.
Full detail in [spike/FINDINGS.md](spike/FINDINGS.md).

**Every control characteristic rejects reads and writes with "Encryption is
insufficient" / "Authentication is insufficient", and macOS never presented a
pairing dialog.** `system_profiler` shows no bond with either bulb. The bulbs are
discoverable and connectable but not controllable.

This is the project's load-bearing risk and the plan is built around it rather than
around a hope that it resolves.

## Goal

A menu-bar app that switches lights on and off, sets brightness / colour temperature
/ colour per light, and saves and recalls scenes — fast enough to feel like a
hardware switch, and good enough that it looks like Apple shipped it.

## Architecture

Three modules, so the risky part is quarantined and the rest stays testable:

```
LumoKit     — domain model. Light, LightState, Scene, SceneStore.
              Knows nothing about Bluetooth.
              protocol LightTransport { discover, connect, apply(state), observe }

LumoBLE     — CoreBluetooth implementation of LightTransport.
              The only file that imports CoreBluetooth.

Lumo (app)  — SwiftUI. MenuBarExtra + Settings window.
              Talks to LightTransport, never to CoreBluetooth.
```

`LightTransport` is the seam that makes the bonding risk survivable. A
`SimulatedTransport` conforming to the same protocol lets the entire UI — sliders,
scenes, menu bar, animation, accessibility — be built, demoed and tested today,
with zero dependency on whether bonding gets solved this week. It is not throwaway
scaffolding: it stays in the repo as the substrate for UI tests and previews.

### State and concurrency

`LightStore` is an `@Observable` on the main actor holding the display model.
`LumoBLE` is an `actor` — CoreBluetooth delegate callbacks land on a dedicated queue
and are funnelled in, so no UI code ever touches a `CBPeripheral`.

Writes are **optimistic**: the UI moves the instant you drag, and reconciles from the
characteristic's `notify` if the bulb disagrees. A slider that waits ~150 ms for a BLE
round-trip before moving feels broken.

Slider drags are **coalesced** — at most one in-flight write per characteristic, with
the latest value superseding any queued one, using `writeWithoutResponse`. Sending
every intermediate value of a drag will saturate the connection interval and lag
visibly behind the thumb.

### Persistence

Scenes as JSON in `~/Library/Application Support/Lumo/`. A scene is
`[LightID: LightState]` plus a name and symbol. Not SwiftData — the data is a handful
of small records, and SwiftData's migration surface is not worth it here.

## The bonding problem: what we do about it

In order of preference, non-destructive first:

1. **Power-cycle a bulb and retry within its pairing window.** Hue firmware accepts
   new bonds for a short period after power-on. Costs nothing to test.
2. **Free the bulb from any active client.** A phone with the Hue app connected can
   occupy the bulb; Hue bulbs hold a small bond table.
3. **Factory-reset one bulb.** Reliable, but it removes the bulb from the existing
   Hue app setup. This is the user's call, not ours, and we do not do it silently.
4. **If none of these work**, the honest conclusion is that macOS's CoreBluetooth
   cannot initiate SMP bonding against this firmware. In that case the app is still
   a real app — against a Hue Bridge over the local HTTPS API v2, which is a far
   more comfortable transport (no range limit, no bond, no 10-bulb cap, supports
   entertainment/streaming). That is a transport swap behind `LightTransport`, not
   a rewrite. It does mean buying a bridge, which is a product decision to make
   deliberately rather than discover at the end.

Milestone 1 exists to answer this before we invest in anything else.

## Milestones

| # | Deliverable | Exit criterion |
|---|---|---|
| 0 | Spike | ✅ done — bulbs found, protocol confirmed, blocker identified |
| 1 | **Bonding resolution** | one real bulb changes state from code, or we commit to the bridge |
| 2 | Prototype | menu bar extra, live discovery, per-light sliders, one saved scene |
| 3 | Scenes | create / rename / reorder / delete, apply from menu bar |
| 4 | Polish | HI review pass, accessibility, launch-at-login, onboarding |
| 5 | Ship | signed, notarised, icon, DMG |

---

# Review

Five passes over the plan above. Each lists what it objected to and what changed as a
result — a review that changed nothing was not a review.

## Apple HI designer

**Objections.**

*A menu that is a menu.* The default `MenuBarExtra` renders an `NSMenu`. Sliders in a
menu are a well-known macOS antipattern — the menu closes on click-through, tracking
fights the menu's event loop, and it looks like a 2009 preference pane. Use
`.menuBarExtraStyle(.window)`, which gives a real popover with real controls, the
same as Control Center and Wi-Fi.

*Two jobs in one surface.* The brief asks the menu bar to do quick on/off and scene
switching. It does not ask it to be the full control panel. Cramming per-light HSB
sliders into the popover makes the common action (lights off) slower. **Popover =
master toggle + scene row + one brightness slider per light. Everything else — colour
pickers, renaming, scene editing — lives in a proper window.** Progressive
disclosure, not a wall of sliders.

*Generic controls for a physical thing.* A brightness slider that looks like a volume
slider wastes the one advantage this app has: it controls something you can see. The
colour-temperature slider must have a real warm→cool gradient track; the colour
control must be a colour field, not three numeric sliders. The light row should show
its actual current colour as a filled swatch, so the popover reads as a picture of
the room.

*Latency is a design problem, not just an engineering one.* If a bulb takes 200 ms to
respond, the UI must not look broken for 200 ms. Optimistic UI is a design
requirement and belongs in the plan, not in an engineer's discretion.

*State legibility.* An unreachable bulb must look different from an off bulb. Off is
a normal state; unreachable is an error. Grey both and the app lies to you.

**Changed in the plan:** popover style switched to `.window`; scope split between
popover and window; gradient tracks and colour swatches specified as requirements;
optimistic UI moved into the architecture section; a distinct `unreachable` state
added to the model.

## macOS / BLE engineer

**Objections.**

*Maintaining N connections is not free.* Each bulb is a separate `CBPeripheral` with
its own connection interval. Holding two is fine; holding ten strains the radio and
will interact badly with whatever other Bluetooth peripherals are already paired. The app
must connect lazily and drop idle connections, not hold every bulb open forever.

*`CBCentralManager` state restoration.* Without it, every app relaunch re-scans and
re-connects from cold, taking seconds. Cache peripheral UUIDs and use
`retrievePeripherals(withIdentifiers:)` — reconnecting to a known peripheral is much
faster than discovery. The spike already captured both UUIDs.

*The spike's toolchain traps will recur in the app.* `NSBluetoothAlwaysUsageDescription`,
the `__TEXT,__info_plist` embedding, TCC responsible-process attribution — all of it
applies to the real app too. Write it down now (done, in FINDINGS.md) rather than
rediscovering it.

*Notifications, not polling.* Every control characteristic supports `notify`.
Subscribe. Polling burns radio time and still shows stale state when someone uses the
physical switch.

**Changed in the plan:** lazy connect + idle disconnect added; peripheral-UUID caching
and `retrievePeripherals` added to Milestone 2; `notify` subscription made the
default rather than an optimisation.

## Security / privacy

**Objections.**

*Bluetooth permission is asked for at the worst moment.* Triggering the TCC prompt on
first launch with no context is how you get denied. Ask after the user presses "Find
my lights", so the prompt has a reason attached.

*The app must degrade honestly when denied.* `CBManagerState.unauthorized` needs a
real UI path to System Settings, not a dead empty state. This is a genuine dead end
for users who tap Don't Allow once.

*Nothing leaves the machine.* No telemetry, no accounts, no network. Worth stating as
a property of the design, and worth keeping true — the app needs no entitlement other
than `com.apple.security.device.bluetooth`.

**Changed in the plan:** permission request moved behind an explicit user action; an
`unauthorized` UI state added alongside `unreachable`; sandbox entitlements pinned to
Bluetooth only.

## QA / reliability

**Objections.**

*The plan tests nothing.* `SimulatedTransport` was introduced as a hedge against the
bonding risk, but its real value is that it makes the app testable at all — you
cannot write a reliable test against a physical bulb. It should also simulate the
nasty cases: slow responses, dropped connections, a bulb that reports a different
value than the one written.

*Scene application is partial-failure-prone.* Applying a 6-light scene where light 4
is unreachable must not leave the user with three lights changed and no explanation.
Decide the semantics now: apply what you can, report what you could not.

*Range is a real failure mode.* This is BLE from a laptop. Walk to the next room and
the lights drop. The app must recover automatically on return, and say so meanwhile.

**Changed in the plan:** fault injection added to `SimulatedTransport`; partial-scene
semantics specified; automatic reconnection with visible state added to Milestone 2.

## Product

**Objections.**

*The riskiest thing is scheduled first — good — but Milestone 1 blocks on physical
access to a bulb.* The prototype must not sit idle waiting. Because `LightTransport`
exists, Milestone 2 can proceed against the simulator in parallel. Do that.

*Ten-bulb ceiling.* Hue BLE tops out around 10 bulbs and has no rooms/zones concept —
those live on the bridge. With two bulbs this is irrelevant; it caps the app's future.
Note it, do not design around it yet.

*"Save scene" is ambiguous.* Does it capture all lights or only the ones on? Capture
everything including off-ness — a scene that cannot turn a light off is not a scene.

**Changed in the plan:** Milestones 1 and 2 explicitly run in parallel; scene
semantics defined as capturing full state including off.

---

## Consequences for the prototype

Building now, in this order:

1. `LumoKit` — model + `LightTransport` + `SimulatedTransport` with fault injection
2. `LumoBLE` — real discovery (works today), real writes (pending bonding)
3. Menu bar popover — master toggle, scene row, per-light brightness, live swatches
4. Scene save/apply against both transports
5. Honest state surfacing: unreachable, unauthorized, and "found but not paired"

Item 5 matters most in the short term: until bonding is resolved, the app's job is to
show you two real bulbs it can see and cannot yet command, and to say exactly that.
