# Lumo

A macOS menu-bar controller for Philips Hue lights. Rooms, real Hue scenes,
per-light colour and brightness, gradients and effects — from the menu bar, without
opening an app.

<p align="center">
  <img src="docs/screenshots/rooms-dark.png" width="330" alt="Lumo's popover showing two rooms, each with its own switch and scene chips">
  &nbsp;&nbsp;
  <img src="docs/screenshots/controls-dark.png" width="330" alt="A light expanded to show brightness, colour temperature with a live Kelvin readout, gradient palettes and built-in effects">
</p>

**Left:** lights are grouped into the rooms defined on your bridge. Each room has its
own switch and its own scene chips; the top switch controls everything. Every
brightness track is tinted with the colour that light is actually emitting, so the
popover reads as a picture of the room.

**Right:** open a light to get colour temperature with a live Kelvin readout,
one-tap temperature presets, gradient palettes for fixtures that support them, and
the bridge's built-in effects. Open several lights in one room at once — matching two
lamps is easier when you can see both. A scene chip is ticked and outlined when the
room genuinely matches that scene, and a temperature preset is outlined when the
light is sitting on it, so you can tell whether the current lighting *is* a preset or
just where the lamps happen to have been left.

<p align="center">
  <img src="docs/screenshots/states-dark.png" width="330" alt="A room where one light is unreachable, shown distinctly from a light that is merely off">
  &nbsp;&nbsp;
  <img src="docs/screenshots/rooms-light.png" width="330" alt="The same popover in light appearance">
</p>

**Left:** an unreachable light never looks like an off light. Off is a normal state;
unreachable is a problem, and the app says which it is. **Right:** light appearance.

Working notes are kept deliberately: [PLAN.md](PLAN.md) has the design and a
five-perspective review of it, and [spike/FINDINGS.md](spike/FINDINGS.md) documents
the reverse-engineered Hue BLE protocol and why direct Bluetooth control is a dead
end on macOS.

## Build and run

Needs Xcode (not just Command Line Tools) — SwiftUI's `@State` is a macro and the
plugin that expands it ships inside Xcode. `build.sh` picks a toolchain via
`DEVELOPER_DIR`, so no `sudo xcode-select` is required.

**Run `./tools/make-signing-identity.sh` once.** Without a stable code-signing
identity, `build.sh` falls back to ad-hoc signing, whose hash changes on every
rebuild — the sandbox then looks like a different app each time and macOS re-prompts
for keychain access to the bridge key on *every single build*. The script creates a
self-signed certificate in the login keychain (user trust domain, no admin needed),
after which one "Always Allow" lasts forever.

```bash
./build.sh && open build/Lumo.app
```

### Liquid Glass, and why there are two builds

Liquid Glass is opted into by the **deployment target**, not by calling
`glassEffect`: building against macOS 26 makes the system restyle the popover chrome
and every standard control. A single binary therefore cannot show the new look on 26+
and the classic one on older systems — the design language is fixed at build time.

So the target is a build parameter and the entire source tree is shared:

```bash
./build.sh                          # macOS 26 baseline — Liquid Glass
LUMO_MACOS_TARGET=14.0 ./build.sh   # macOS 14 baseline — classic appearance
```

There is deliberately no explicit `glassEffect` anywhere. Applied by hand to chips
and panels it measured as indistinguishable from a translucent tinted capsule — at
that size, on a popover that is already a system material, there is nothing for glass
to refract. The system does the real work.

Tests:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

UI snapshots — renders the popover in every interesting state, light and dark, to
PNG. Run the **unsandboxed** binary from `.build`; the signed bundle cannot write
outside its container:

```bash
.build/release/Lumo --snapshot /tmp/lumo-shots
```

Capturing **Liquid Glass needs Screen Recording permission**, because glass is
composited by the window server rather than drawn by the view tree — nothing
in-process can see it. Grant it under System Settings > Privacy & Security > Screen &
System Audio Recording for the binary you run. Without the permission the run still
produces images, drawing the classic fallback and printing `Liquid Glass MISSING` for
every file, so the screenshots can never quietly claim to show something they do not.

The shots are taken in the popover's own material, so they show the translucency the
app actually has. Behind it sits a fixed neutral gradient by default, which keeps a
run reproducible. `LUMO_SNAPSHOT_BACKDROP=desktop` photographs the real wallpaper
instead and puts the popover on that. Useful for looking at a change locally; not for
anything committed, since it puts your desktop — and whoever's artwork it is — into
the repository.

## Current state

**Working end to end via the Hue Bridge.** Every light the bridge reports is
discovered and controllable; a write self-test passes on each one.

Lights are grouped into the **rooms defined on the bridge**, so Lumo matches the Hue
app and any wall switch rather than inventing a second grouping to keep in sync. Each
room has its own switch (one `grouped_light` call, so the room switches instead of
rippling) and its own scenes.

**Scenes are real Hue scenes.** Lumo lists the ones already on the bridge — including
those made in the Hue app, gradients and all — and recalling one is a single request
that the bridge executes. Saving a scene creates a genuine Hue scene in that room, so
it appears in the Hue app immediately. Scenes Lumo created are tagged and are the only
ones it offers to delete: a scene built in the Hue app may be wired to a routine or a
switch, which is not a thing to discard from a popover.

### Rooms, gradients and effects

Each light's disclosure exposes what that fixture actually supports, read from the
bridge rather than hard-coded:

- **Colour-temperature presets** under the temperature slider — one tap for candle,
  warm, reading or cool light. On a gradient fixture these are also the way back to
  ordinary flat room lighting, because writing a colour temperature is what makes
  the bridge clear the gradient.
- **Gradient palettes** for fixtures like the Play lamps (5 colour points across 8
  pixels). Only genuinely multi-colour looks appear here: a "uniform gradient" of
  five identical points is flat colour wearing a gradient's clothes and is
  indistinguishable from setting a colour temperature, so those belong with the
  temperature control instead. There is no "None" chip either — writing any flat
  colour clears the gradient (verified: 5 points before, 0 after either an xy or a
  colour-temperature write), so the presets and the colour slider are already the
  ways out, and each lands somewhere deliberate.
- **Built-in effects** the bridge reports for that lamp: candle, fire, prism,
  sparkle, opal, glisten, underwater, cosmos, sunbeam, enchant.

The popover sizes itself to its content, up to the room available below the menu
bar, so a handful of lamps needs no scrolling. There is deliberately no resize
handle: menu-bar popovers on macOS are not resizable, and Control Center, Wi-Fi and
Now Playing all size to content.

Rapid scene switching is coalesced. Hue applies a scene as a *transition*, and
recalling a second scene mid-transition interrupts the first — flipping between two
scenes repeatedly left one lamp at 28% and its pair at 32%, matching neither. Only
the last scene in a burst is sent, and a stale refresh cannot overwrite a newer one.

`--make-presets "<room>"` creates Evening (2700 K, 70%), Reading (3300 K, 100%) and
Candlelight (2000 K, 28%) as real Hue scenes in that room. Each pins a *uniform*
gradient as well as a colour temperature, so a gradient fixture lights the room
evenly instead of keeping whatever multicolour spread was last active. Re-running
replaces the same-named presets rather than stacking duplicates.

Two transports, chosen from the gear menu in the header (the choice only appears when there is one):

| Mode | State |
|---|---|
| **Bridge** | Works. Rooms, scenes, per-light control. Default when paired. |
| **Bluetooth** | Discovery works; commands rejected — the bulbs will not bond with macOS. |

`SimulatedTransport` still exists but is no longer user-selectable — it backs the
tests and the offscreen snapshots, where a deterministic set of lights is the point.

Direct BLE remains blocked (`Encryption is insufficient`, no pairing prompt, bulbs
bonded to the Hue app). The bridge makes that moot: no bond, no range limit, no
ten-bulb ceiling, and push updates when anyone changes a light from anywhere.

### Bridge setup

Pairing needs a physical button press. Run this and press the round button on the
Bridge within 60 seconds. Launch through LaunchServices (`open -n`) so the
local-network permission prompt attaches to the app rather than the calling shell:

```bash
open -n -W build/Lumo.app --args --pair-bridge <bridge-ip>
```

Then verify — `--verify-bridge` lists every light, `--test-lights` briefly flashes
each one and restores its exact prior state:

```bash
open -n -W build/Lumo.app --args --verify-bridge
```

`--discover` reports how Lumo would find the bridge again, and
`--test-relocate <bogus-ip>` proves recovery by deliberately poisoning the stored
address and checking that it re-homes.

CLI output goes to `~/Library/Containers/dev.lumo.Lumo/Data/lumo-cli.log`, because
`open` detaches stdout.

### Surviving a DHCP lease change

Bridges move. Lumo stores the bridge's **mDNS name** (`aabbcc112233.local`), derived
from its ID by removing the `fffe` EUI-64 padding, so the address follows the device
with no discovery at all. If a request fails in a way that looks like a bad address,
the transport re-homes to that name mid-session, replays the request once, and writes
the working address back to the Keychain.

Bonjour *browsing* was implemented for this and then removed: browsing works, but
resolving a discovered endpoint to an address never completes under the app sandbox —
`NWConnection` sits in `.preparing` indefinitely. A fallback that cannot fire is worse
than none, and the derived name needs no browsing, since the bridge ID is known once
paired.

The application key is stored in the **Keychain**, never in the repo. Every
connection after pairing is pinned to the bridge's certificate, whose common name is
the bridge ID — so a device that seizes the bridge's DHCP address cannot impersonate
it.

### Retrying direct BLE

```bash
cd spike && ./bundle.sh && open -W build/HueScan.app --args 60 pair && grep -E "BONDED|attempts" ~/huescan.log
```

## Diagnosing it years from now

Lumo sends no telemetry. Nothing leaves the machine on its own, and that is a
property worth keeping — so the diagnostics are things a person can produce *after*
something went wrong, with nothing enabled in advance.

**Copy Diagnostics** in the gear menu puts a health report on the clipboard:
build and OS versions, which appearance the binary was built for, bridge address and
key fingerprint, how long since the last sync and the last pushed event, and counts
of lights, rooms and scenes. It deliberately contains **no light, room or scene
names** — those name things in someone's home, they are never needed to debug a
connection, and reports get pasted in public. `--diagnose` prints the same report and
exits non-zero when something is actually wrong, so it can be scripted.

**Logs** go to the unified log under subsystem `dev.lumo.Lumo`, with categories
`transport`, `store`, `ui` and `setup`. Light and room names are logged as
`%{private}` and redacted unless the user deliberately collects private data:

```bash
log show --predicate 'subsystem == "dev.lumo.Lumo"' --last 1h --info --debug
```

**Failures are shown.** Every failure path reports through `LightStore.report`,
which logs it and raises a banner that clears itself. Errors used to be recorded and
never displayed, so a refused write looked like the app ignoring you.

**Contract tests** in `Tests/LumoBridgeTests` decode recorded bridge responses. The
bridge is somebody else's firmware and its payload shape changes without notice;
every fixture encodes something that actually broke this app or would have — partial
events, rooms listing devices rather than lights, `status.active`, gradient point
counts. They need no hardware, so CI runs them on every push, against both build
variants.

The hardware suite still needs a human and a bridge: `--verify-bridge`,
`--test-lights`, `--test-scene-switch`, `--test-relocate`, `--test-scenes`.

## Layout

```
Sources/LumoKit    domain model, LightTransport, SimulatedTransport, scenes
Sources/LumoBLE    the only target that imports CoreBluetooth
Sources/LumoBridge Hue Bridge over the local CLIP v2 API
Sources/Lumo       menu-bar app (NSStatusItem + NSPopover hosting SwiftUI)
                   plus an offscreen snapshot renderer
spike/             standalone BLE scanner used to characterise the bulbs
```

`LightTransport` is the seam, and it paid for itself: adding the Bridge transport
touched nothing above it — no view, no store, no scene code changed.

The menu bar item is an `NSStatusItem` with an `NSPopover`, not SwiftUI's
`MenuBarExtra`. `MenuBarExtra(.window)` does not keep its panel anchored to the
status item across content-size changes: it lays out new content one pass before the
window follows and draws the difference centred, so expanding a light made the
popover grow from the top and bottom at once and drift away from the menu bar. All
the SwiftUI view code is unchanged — only the hosting differs.

Screenshots in this README are rendered from `SimulatedTransport` by
`Lumo --snapshot <dir>`, so they are reproducible and show no real hardware.

## Licence

MIT — see [LICENSE](LICENSE).
