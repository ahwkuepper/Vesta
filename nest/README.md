# Persistent Nest reader

An opt-in, read-only macOS command-line companion for Google Nest thermostats.
It is a separate Swift package; the original Vesta and Vesta Kasa do not link it. Nest readings
come from Google's cloud, not the local network. Apple frameworks only.

The separate [Vesta Home app](../home/README.md) now reuses this source and Keychain
authorization with thermostat control explicitly enabled. The command-line reader
remains read-only: its default HTTP client rejects all command endpoints.

## Build and read

From the repository root:

```sh
./nest/build.sh
./nest/reader read
./nest/reader read --json
./nest/reader status
```

The signed executable lives at `.build/nest-reader/nest-reader`. The wrapper never
rebuilds implicitly. Builds require the stable `Vesta Development` signing identity
(or `VESTA_SIGNING_IDENTITY`). Rebuilding with a different identity can trigger
Keychain approval. `status` checks local storage, not whether Google still accepts
the saved token. JSON includes retrieval time and thermostat readings, without
Google device IDs. Offline readings are explicitly marked in text and retain their
connectivity status in JSON. Retrieval time is not the sensor's measurement time.

## First authorization

1. Register a personal project in [Nest Device Access](https://console.nest.google.com/device-access).
2. Enable Smart Device Management in Google Cloud and create a Web OAuth client.
   Set its redirect URI to exactly `https://www.google.com`. Attach its client ID
   to the Nest Device Access project. Download the client credentials JSON locally.
3. In Google Auth Platform → Audience, add your Google account as a test user.
   For lasting authorization, change the OAuth publishing status to **In production**
   before authorizing. If publishing is blocked by incomplete Branding, fill in
   the app name and contact emails plus these public pages:
   Use pages and a domain you control if Google requires ownership verification.
   The project's [site source](site/README.md) can be adapted for your installation;
   do not claim ownership of the maintainer's domain. Home users should follow
   the complete [Home setup guide](../home/SETUP.md).
   Testing grants and refresh tokens expire after seven days.
   Personal Nest integrations do not require OAuth verification, although Google
   may display an unverified-app warning. The Nest Device Access project itself
   can remain in Sandbox; that is a different setting.
4. Import the credentials and print a consent link:

   ```sh
   ./nest/reader setup --credentials "$HOME/Downloads/credentials.json" --project YOUR_DEVICE_ACCESS_UUID
   ./nest/reader authorize
   ```

5. Open that **new** link and authorize the desired home and thermostat. Save the
   complete returned Google URL as a UTF-8 text file, e.g.
   `~/Downloads/nest-authorization.txt`. It must contain both `code` and `state`.
   Do not paste it into chat, a shell argument, a repository, or a public issue.
6. Immediately run:

   ```sh
   ./nest/reader connect --authorization "$HOME/Downloads/nest-authorization.txt"
   ./nest/reader read
   ```

`connect` stores the refresh token in Keychain **before** requesting device readings.
A device API failure therefore leaves the saved authorization available for a later
`read`. Each read obtains a fresh short-lived access token; it does not need the
downloaded JSON or redirect file. After a successful connection, remove those
temporary files yourself if you no longer need them. The tool does not delete them.
It doesn't save access tokens, authorization codes, or readings to disk.

Every `authorize` starts a new attempt and invalidates earlier links for this reader.
Pending attempts expire after 20 minutes; Google's authorization code can expire
sooner. Expired/revoked refresh tokens need a new authorize/connect cycle, without
repeating setup. Google's documentation requires refresh-token use within six
months to maintain authorization; this is an on-demand tool, not a scheduled job.

## Credential handling and network boundary

Security-relevant change: constitution Articles 1, 4, 5, 6, and 7.

- Keychain service: `io.github.ahwkuepper.NestReader.oauth`, account: `google-sdm`.
  Stores the OAuth client ID/secret, Device Access project UUID, refresh token,
  optional Google-reported expiration, and pending OAuth state. ThisDeviceOnly,
  no iCloud Keychain sync. The reader never accesses Hue or Kasa entries.
- Only HTTPS port 443, system certificate validation. POST to
  `oauth2.googleapis.com/token`, GET to
  `smartdevicemanagement.googleapis.com/v1/enterprises/{UUID}/devices`.
  The public consent URL goes to `nestservices.google.com`. Imported credential
  files cannot override these endpoints. All HTTP redirects are refused.
- Read-only **implementation**, not a read-only OAuth grant: Google's `sdm.service`
  scope can also control devices. Protect the refresh token accordingly.
- Ephemeral HTTP sessions: no cookie store, URL credential store, or disk cache.
  20-second request / 30-second resource timeout, 1 MB response and 64 KB file limits.
  HTTP errors are mapped to fixed messages; response bodies and secrets are not logged.
  Normal readings intentionally include room names, so don't treat them as anonymous diagnostics.
- A process lock serializes CLI operations so simultaneous runs don't overwrite
  a rotated refresh token or a pending authorization. `read` never retries a rejected
  token, permission failure, or rate limit automatically.
- `./nest/reader forget` removes only this tool's Keychain entry. To revoke Google's
  authorization too, unlink the project in [Nest Partner Connections](https://nestservices.google.com/partnerconnections).
  Reconfiguring a different project/client requires this explicit reset.

## Verification

```sh
./nest/test.sh
```

Tests use synthetic responses and an in-memory credential store. They cover
authorization state validation, token renewal across reader instances, rotation,
persisting before a failed API read, Keychain failure before code consumption,
expired/revoked grants, redacted errors, endpoint restrictions, malformed responses,
missing traits, offline state, and Eco thresholds. They do not contact Google or
modify the real Keychain. After real authorization, run `read` in two separate
processes to verify actual Keychain persistence and renewal.

Protocol sources:
[Google setup](https://developers.google.com/nest/device-access/get-started),
[authorization and refresh](https://developers.google.com/nest/device-access/authorize),
[OAuth testing limits](https://support.google.com/cloud/answer/15549945),
[thermostat traits](https://developers.google.com/nest/device-access/api/thermostat).

## Public website

The static pages are kept in `nest/site/` and published separately in
[vesta-nest-site](https://github.com/ahwkuepper/vesta-nest-site), using GitHub Pages
from that repository's `main` root. Its history contains only public website files.
Changes in this private checkout do not automatically update that public repository.
Review and copy only the website files when updating it; never push this repository's
history or any OAuth files to the website repository.
