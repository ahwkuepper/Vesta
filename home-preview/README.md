# Vesta Home Preview

An interactive native macOS prototype for a unified Hue, Kasa and Nest interface.
All readings and devices are samples. Controls change in-memory state only; the
preview has no network entitlement, transports or Keychain access.

## Try it

Run `./build-home-preview.sh` from the repository root, then open
`.build/home-preview/Vesta Home Preview.app`. It opens a comparison window and adds
a house icon to the menu bar. The existing Hue and Kasa apps remain separate.

The three layouts share state, so changing a light updates every column:

- **Quick access:** favorites first, followed by remaining lights and devices.
- **By room:** lights and appliances grouped by location, with room light switches.
- **Tabs:** separate Lights and Devices lists, each filterable by room.

Choose “Try … in menu bar” under a column to use that layout in the popover. The
ellipsis menu can switch layouts, reopen the comparison, reset or quit. Only the
chosen layout persists between launches.

Click Hallway/current temperature to expand humidity, mode, Eco and temperature
units. The target has direct minus/plus buttons. Everything is simulated, including
the heating state and Eco threshold.

Click a device name to expand its controls and room assignment. A plug's “Use as”
setting classifies it as a light or another device. Lamp plugs share the light list
but expose only on/off controls. Color and warmth controls appear only on capable
sample bulbs. Scene buttons and room switches exclude appliances and unavailable
devices.

## Build and verify

Requires full Xcode for Swift Testing. The build script selects it through
`nest/toolchain.sh`, links against the installed macOS SDK and signs with the existing
Vesta development identity when available. It shares Vesta's native design controls,
Liquid Glass styles and 330-point popover width, with classic fallbacks.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VESTA_CLASSIC=1 swift test
tools/check-boundaries.sh
tools/check-no-secrets.sh
./build-home-preview.sh
```

For deterministic PNGs, run the unbundled executable with `--snapshot OUTPUT_DIR`.
Snapshots use flat fallback materials because offscreen rendering does not capture
the window compositor's Liquid Glass background. The running app uses native
materials. Tests cover classification, group controls, capabilities, temperature
units and limits, and expanded layouts at three constrained heights.

## Next implementation stage

Connecting actual devices requires provider adapters, persistent room/classification
overrides and connection/error states. Nest's existing companion is read-only;
thermostat writes and a cloud-enabled combined app require an explicit architecture
update. No working app has been replaced by this prototype.
