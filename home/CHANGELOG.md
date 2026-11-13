# Vesta Home changes

## 0.2.6 — Hue connection recovery

- Hue Bridge failures report local-network or pairing problems instead of a
  Bluetooth warning. A successful refresh clears stale availability and restores
  the event subscription after a failed startup.
- Added regressions for startup recovery, later disconnect/reconnect, revoked
  pairing and a single live event subscription across repeated refreshes.

## 0.2.5 — room layout refinement

- Consistent room-section insets, header height and separation before controls.
  Room symbols and titles align with device swatches and names.
- Scene chips have internal breathing room for their glass edges; the redundant
  vendor caption is removed, with scene context retained for accessibility.
- Offline previews now include scenes and collapsed-room layouts.

## 0.2.4 — single-device room controls

- Single-device rooms show power only on the device row while expanded, and on
  the room header while collapsed. Multi-device rooms retain their light group
  controls. A collapsed single appliance can be controlled directly without
  adding it to any room-wide or global light group.

## 0.2.3 — quieter room headers

- Moved per-room priority choices into Home settings → Room priority. Room headers
  now contain only expansion and light controls; saved priorities are retained.

## 0.2.2 — thermostat interaction candidate

- Temperature taps update a local draft, then send one command after an 800 ms pause.
  Returning to the original target cancels the change; changing thermostat or mode
  cancels the previous draft. Heating/cooling ranges retain their required gap.
- Reopening the menu reuses readings for 60 seconds. Command readback fetches only
  the changed device, reducing full device-list requests.
- Google rate limits pause requests for at least a minute, honoring Retry-After.
  Recovery refreshes readings only; unconfirmed commands are never replayed.

## 0.2.1 — adaptive sorting candidate

- Smart room order puts everyday lights that are on first, then recently used rooms.
  Deliberate controls in Home update a small local usage summary; automatic changes
  and global light actions do not train the order.
- Garage/storage rooms start low. Charger and seasonal-decoration names start as
  background devices; their on state does not dominate room order. Explicit room
  and device preferences override these editable guesses.
- Order stays stable while the menu is open. Smart sorting can be disabled and its
  learned summary reset. Layout export transfers choices but excludes usage history.

## 0.2.0 — initial combined-app candidate

- Hue and Kasa lights and lamp plugs appear together by room. Other plugs remain
  separate appliances; group light actions exclude them.
- Nest temperature appears at the top, with optional setpoint, mode and Eco controls.
  Nest requires your own Google project and authorization.
- Hue scenes and Kasa schedules expand inside the device/room interface.
- Room assignments, plug classifications and units can be exported to another Mac;
  credentials are configured separately.
- Added first-install setup, Home privacy documentation and a dedicated attested
  Home release workflow. Publication scanning covers untracked files and reviewed
  binary assets.

This is a candidate, not an announcement that a public installer is available.
See [validation status](VALIDATION.md) for outstanding device and platform checks.

## 0.1.1 — personal installer

Signed and notarized universal installer for personal testing, with layout export
and import. Not published through the public source/attestation release workflow.
