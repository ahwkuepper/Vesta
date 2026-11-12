# Vesta Home

A native macOS menu-bar app combining Hue Bridge lights, Kasa bulbs and plugs, and
Nest thermostats in the chosen room-based layout. Build with `./build-home.sh`, then
open `.build/home/Vesta Home.app`. The installed app uses the house menu-bar icon.

**Public beta candidate:** start with the [setup guide](SETUP.md). Read the
[privacy policy](PRIVACY.md), [release notes](CHANGELOG.md) and
[validation status](VALIDATION.md). Nest is optional and requires your own Google
project. The current personal installer is not a public, CI-attested release.

## Daily use

- Temperature stays at the top. Click the current temperature to expand humidity,
  supported thermostat modes, Eco, units and refresh. Heat/cool targets have direct
  minus/plus controls. Auto mode shows both targets in the expanded panel.
- Every room contains its lights and other devices. Room switches and “All lights
  off” affect only lights. Open a plug and choose **Use as → Light** when it powers
  a lamp; unknown plugs default to Device. Bulbs and lamp plugs share the same row
  style. Dimming and color controls appear only when supported.
- Hue rooms are read from the bridge. Kasa names matching an existing Hue room are
  grouped there; other devices start in Unassigned. Each device has a room picker.
  Add rooms under **Connections & rooms**. Assignments are saved locally and do not
  rename or move devices in the vendor apps.
- Use **Rooms → Export layout / Import layout** to transfer room assignments,
  plug classifications and temperature units between your Macs. Imports merge
  settings, replacing assignments for matching devices. Files contain room names
  and device identifiers but no credentials or device state; transfer them privately.
- Existing Hue scenes appear within their original room and apply to Hue devices
  only. Kasa schedules expand inside each Kasa device, using the existing scheduler.

## Smart room order

Enabled by default. Rooms with reachable everyday lights on come first, followed
by the rooms you controlled most recently in Home. Order is fixed while the menu
is open and refreshed on reopening, so a toggle or slider cannot move under you.
Newly discovered rooms append until the next opening.

Only deliberate Home controls count: power, dimming, color, effects, a room switch
or a Hue scene. Polls, schedule changes and global All lights actions do not create
usage records. The app does not know whether a change from another app was manual.
Repeated slider events coalesce. A compact per-room last-use/frequency summary
stays in this Mac's preferences; older habits fade. No cloud AI service is used.

Garage/storage rooms start low, and repeated manual use can overcome that initial
guess. Charger and seasonal-decoration names start as background devices: being on
does not raise their room. Other lights in the same room still count. These are
editable initial guesses, not a claim that the app can inspect every vendor's
schedules. Use the room's **… → Keep low** to keep it below ordinary rooms regardless
of activity, or **Normal priority** to override the utility-room guess. In a device's
controls, **Smart order → Everyday / Background** overrides its name-based guess.
These sorting choices do not alter device schedules, classification or group actions.

Turn off **Smart room order** for alphabetical order and to pause learning.
**Reset learned order…** deletes the usage summary while preserving explicit choices.
Layout export transfers those choices and the sorting toggle, but never usage
history. Learning remains separate on each Mac.

## Connections

The app reuses the existing provider-specific Keychain entries. macOS may request
access once because Vesta Home has a new bundle identity. Wake and unlock the Mac
before first launch; macOS cannot display Keychain prompts during dark wake.
Reopen the menu or use the connection-specific refresh buttons after allowing access.

The connections page supports Hue pairing, Kasa account sign-in and Nest OAuth
reconnection. Nest uses the project and client already configured by the persistent
reader. New installations can import a Google web-client JSON and Device Access
project ID there. Authorization opens Google's consent page; paste the returned URL
into the secure field to finish. It is used in memory and never written to logs or
preferences. Don't run the standalone reader's authorization flow concurrently.

Hue uses bridge events with periodic readback. Kasa reads every 10 seconds and
rediscovers periodically. Nest refreshes once a minute, and on reopening the menu;
after a failure, automatic Nest polling pauses until a manual refresh or reopening.
Failed/stale Nest readings remain visibly marked and cannot be used to send commands.
Thermostat changes are sent once and read back. A failed response never causes an
automatic repeat of a thermostat command.

## Security-relevant architecture

This app is an explicit opt-in exception to Vesta's local-only architecture (see
constitution Articles 1, 4, 5 and 7). The original Vesta and Vesta Kasa apps remain
local-only. The layout preview remains disconnected and sample-only.

- Apple frameworks only; no new third-party libraries.
- Hue uses the existing pinned bridge transport and scoped credential service.
- Kasa uses local discovery, legacy XOR or authenticated KLAP, with the existing
  account-derived keys in Keychain. Local target checks and response limits remain.
- Nest uses HTTPS to Google's OAuth token and SDM endpoints. Home opts into five
  thermostat commands; the standalone reader's default transport still rejects all
  command endpoints. Commands must target a thermostat from a fresh authorized
  device list and match its current mode, connectivity, Eco state and app limits.
- The app's conservative temperature adjustment range is 10–32°C. Range mode keeps
  cooling at least 0.5°C above heating; Google/device-specific limits may still reject
  a change, which is surfaced. Unsupported modes aren't offered.
- No credentials, OAuth URLs or Google resource IDs are logged. The startup check
  logs provider counts only. Google IDs remain in memory and are excluded from CLI
  JSON. No real device settings are changed by startup, refresh or snapshots.
- Sandboxed, with network client/server entitlements for local discovery and reads,
  and user-selected read/write access for importing credentials and transferring
  layout files. ATS allows numeric-IP
  HTTP for Kasa KLAP; its transport validates local destinations. Nest separately
  enforces HTTPS, method/host/path allowlists, time/size limits and no redirects.
- Stable development signing is required. Room/classification overrides and units
  are stored in the app's own preferences, keyed by provider plus device ID.

## Verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VESTA_CLASSIC=1 swift test
./nest/test.sh
tools/check-boundaries.sh
tools/check-no-secrets.sh
```

The unbundled executable supports `--snapshot OUTPUT_DIR` with synthetic fixtures
and flat materials for repeatable visual inspection. This mode never starts device
transports or loads credentials. The installed app uses native Liquid Glass where
available. Automated command tests use synthetic responses, not home hardware.

Nest command references: [setpoints](https://developers.google.com/nest/device-access/traits/device/thermostat-temperature-setpoint),
[modes](https://developers.google.com/nest/device-access/traits/device/thermostat-mode),
[Eco](https://developers.google.com/nest/device-access/traits/device/thermostat-eco).

## Private installer

`tools/package-home.sh` builds a universal optimized app using the pinned Xcode,
signs with Developer ID, notarizes and staples the app and DMG, and checks both with
Gatekeeper. It uses the existing `vesta-notary` Keychain profile. The output is
`build/Vesta-Home-VERSION-universal.dmg`, plus its checksum and build metadata.
The script makes no GitHub release, public tag or CI-attestation claim. It refuses
to overwrite an existing installer of the same version.

The DMG includes an Applications shortcut and [installation instructions](INSTALL.txt).
Credentials are configured separately on each Mac; the installer never includes
OAuth client files or saved credentials. Installers follow Apple's
[Developer ID notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Public release workflow

Follow [RELEASING.md](RELEASING.md). Home has a separate `home-v*` tag namespace,
canonical unsigned build, manifest comparison and GitHub provenance workflow.
`tools/release-home.sh sign VERSION` only packages a public-tag build with a valid
attestation for that exact commit and the Home workflow. Private history is never
published; `tools/prepare-public-snapshot.sh` prepares a separate source repository.
