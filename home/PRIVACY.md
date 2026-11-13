# Vesta Home privacy

Effective November 11, 2026. This policy covers the Vesta Home macOS app developed
by Andreas Kupper. The original Hue-only Vesta and the read-only Nest CLI are
separate applications. Home can change thermostat settings when you request it.

## Access and network use

Hue and Kasa discovery, readings and commands use your local network. This may
include device identifiers, names, room and scene information, power, brightness,
color, schedules and device clocks. Legacy Kasa local control is not authenticated;
keep your home network private. Kasa account input is used to derive local
authentication keys; Home does not sign in to a TP-Link cloud service.

Nest is optional and uses Google's OAuth and Smart Device Management APIs over
HTTPS. It accesses authorized device identifiers, room names, temperature, humidity,
setpoints, operating mode, Eco, HVAC activity and connectivity. Home can send
heating/cooling targets, thermostat mode and Eco commands. Google's `sdm.service`
scope permits control; the separate CLI's read-only implementation does not make
its OAuth grant read-only. Your Google password is entered on Google's page.

There is no developer-operated backend, analytics, advertising, crash-reporting
service or automatic update check. Home does not send readings or credentials to
the developer. Google processes Nest requests under its own
[privacy policy](https://policies.google.com/privacy). Opening a documentation or
consent link sends your browser to that site's operator; app telemetry is not added.

## What stays on the Mac

Provider-specific Keychain entries store Hue pairing credentials, Kasa account-derived
keys and Nest client configuration and refresh tokens. These credentials are not
included in installers or layout exports. Home reuses the original Vesta, Vesta Kasa
and Nest reader entries when permitted by macOS; changing or deleting a shared
entry can affect those apps. Nest credentials do not sync through iCloud Keychain.

Home's preferences retain room assignments, plug classifications, sorting choices
and units. When Smart room order is enabled, Home also keeps a compact per-room
last-use timestamp and decaying frequency summary of deliberate controls in Home.
It does not keep a chronological event log or send this summary to a server or AI
service. Polls, schedules and global light actions do not count as manual use.
Disable Smart room order to pause learning; Reset learned order deletes the summary.
Explicit sorting preferences can be exported with a layout; usage history cannot. Kasa
also caches device names, identifiers, local addresses, capabilities and last-known
state to show devices during discovery. Nest access tokens and readings are held
in memory, not a readings database. Diagnostic messages are intended to omit
credentials and identifying readings; macOS manages log retention.

Downloaded OAuth client JSON, browser history/clipboard containing a returned URL,
layout exports and screenshots may remain outside Home. Home does not delete
these. Protect or remove them yourself. Layout exports contain room names and
device identifiers, but no credentials or power/temperature state. Local preferences
and files can be included in backups according to your Mac's backup configuration.

## Disconnect and delete

Revoke Nest access in [Google Nest Partner Connections](https://nestservices.google.com/partnerconnections).
To remove local Nest authorization, quit Home and the reader, then delete the
Keychain item with service `io.github.ahwkuepper.NestReader.oauth` and account
`google-sdm` in Keychain Access. Removing this item is distinct from revoking Google's
grant. Kasa's Account view offers sign-out; Hue pairing can be removed through the
vendor's authorized-app controls and the `io.github.ahwkuepper.Vesta.bridge`
Keychain item. These entries may be shared with the companion apps.

Deleting the application alone does not remove preferences or Keychain items.
To remove cached device information and layout, quit Home and remove its sandbox
container `~/Library/Containers/io.github.ahwkuepper.VestaHome` in Finder. Delete
exported files and setup files separately. Vendor-side schedules remain on devices.

## Google data and questions

Google user data is not sold, used for advertising or used to train generalized AI
models. Use and transfer of Google API information adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including Limited Use requirements.

Updates to this policy will carry a new effective date. Use the repository's issue
tracker for questions without personal data, or a private security advisory for
vulnerabilities. Public issues and uploaded screenshots can be read by others.
