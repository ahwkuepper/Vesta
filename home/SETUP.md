# Set up Vesta Home

Vesta Home combines Hue Bridge lights, compatible Kasa lights and plugs, and an
optional Nest thermostat. Each provider can be connected separately. macOS 14 or
later is required; the universal build supports Apple silicon and Intel.

This is beta software. See [validation status](VALIDATION.md) for what has actually
been tested and [privacy](PRIVACY.md) for local storage and cloud access.

## Install and connect lights

1. Download a **Vesta Home** DMG from the project's GitHub Releases page when a
   Home beta is available. Hue-only Vesta is a different download. Compare its
   checksum with the supplied `.sha256` file using `shasum -a 256`.
2. Quit an existing Home copy, open the DMG and drag Vesta Home to Applications.
   Open it from Applications; click the house in the menu bar.
3. Allow Local Network access when macOS asks. Open **… → Connections & rooms**.
4. For Hue, choose **Pair bridge…**, follow discovery and press the bridge's
   physical link button when prompted. Home requires a bridge for Hue; it does not
   expose the original Vesta app's Bluetooth-only mode.
5. For Kasa, choose **Find devices** on the same LAN. If a device asks for sign-in,
   open **Account…** and enter your TP-Link account. Some firmware uses an older
   local protocol; other firmware requires authenticated KLAP even on similar
   hardware. If authentication fails, check the account and the vendor app's
   Third-Party Compatibility option where available. Not every Kasa/Tapo model or
   firmware is supported. Device errors do not mean a command was safely retried.

Smart room order learns from your controls in Home. Room order updates when you
reopen the menu. Use a room’s **… → Keep low** for places you rarely need, or choose
**Background** in a device’s Smart order setting for scheduled decorations. You can
disable learning or reset it in the Home menu.

Open a device to assign its room or classify a plug as a light. Group light
switches exclude plugs classified as appliances. Hue scenes apply only to their
original Hue room. Kasa schedules are stored on the device; check its clock in the
vendor app if a schedule runs at the wrong time.

## Optional Nest setup

Nest uses Google's cloud. This beta supplies no shared Google client or developer
backend: configure your own project for personal use. Hue and Kasa work without it.
A Google Developer profile alone is not a Device Access project.

1. Follow Google's [Device Access quick start](https://developers.google.com/nest/device-access/get-started)
   to register, enable Smart Device Management in a Google Cloud project and create
   a Device Access project. Google currently charges a US$5 one-time registration
   fee. Use the account that owns your supported thermostat.
2. Create a **Web application / Web server** OAuth client. Set its authorized
   redirect URI to exactly `https://www.google.com`. Download its client JSON and
   attach that client ID to your Device Access project. The Device Access project
   UUID is different from the Google Cloud project name or number.
3. In Google Auth Platform, configure Branding and Audience. While the OAuth app
   is **Testing**, add your own account as a test user. For persistent use, complete
   the required branding fields and switch OAuth publishing status to **In production**,
   then authorize again. Use your own contact details and pages you control if
   Google requires domain verification; do not claim the maintainer's domain.
   You can adapt the [site source](../nest/site/README.md) for a personal installation.
4. In Home's Connections page, expand **Set up Nest**. Enter the Device Access
   project UUID, import the JSON, then choose **Authorize…**. Approve your home and
   thermostat in the browser. Confirm the consent screen names your own project.
5. After Google redirects, copy the **complete address-bar URL**, including `code`
   and `state`, into Home's **Returned URL** field. Choose **Finish connection**.
   Keep this URL out of chat, public issues and shell commands. Home exchanges it
   in memory and saves the resulting authorization in this Mac's Keychain.
6. Check the displayed reading against the vendor app. Remove your downloaded
   credential file and any saved redirect URL when no longer needed, or keep them
   in secure storage for setting up another Mac.

Google's [authorization guide](https://developers.google.com/nest/device-access/authorize)
explains the consent flow. For personal Device Access, Google says OAuth verification
is not required; an unverified-app warning may still appear. A Testing grant can
expire after seven days. See Google's [authorization troubleshooting](https://developers.google.com/nest/device-access/reference/errors/authorization).
OAuth **In production** is separate from Device Access **Sandbox** and does not
certify a public integration. Google describes personal Sandbox use and commercial
requirements [separately](https://developers.google.com/nest/device-access/project/apply).
This beta does not claim commercial Nest certification or provide public sign-in
through the maintainer's project.

## Recovery and another Mac

- **No devices:** verify home Wi-Fi, Local Network permission and any VPN or guest
  network isolation. Retry discovery. Nest also needs internet access.
- **No Keychain prompt:** wake and unlock the Mac, then reopen Home. A changed
  signing identity may require access again. Do not delete saved credentials just
  because a prompt has not appeared.
- **Google access denied:** verify the account is a test user while Testing, and
  the client ID matches the Device Access project. A redirect mismatch requires
  the exact URI above. Start a new authorization attempt for an expired code.
- **Stale thermostat:** Home disables controls when its last read failed. Use
  Refresh after restoring connectivity. Frequent commands or several Macs polling
  one project can reach Google's [rate limits](https://developers.google.com/nest/device-access/project/limits).
- **Another Mac:** install the same app, pair Hue, sign in to Kasa, and configure
  Nest with your existing project and client JSON transferred privately. Authorize
  each Mac. Do not run the CLI and Home authorization flows concurrently.
- **Rooms:** export layout on the first Mac and import it on the other. This
  transfers room assignments, plug classifications and units, not credentials.
  Settings do not synchronize automatically.

For bugs, use the repository's issue tracker. Include app/macOS versions and model
and firmware details; remove device IDs, addresses, room names and credentials
from attachments. Report vulnerabilities using a private security advisory.
