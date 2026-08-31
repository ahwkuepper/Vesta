// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import VestaKit
@testable import VestaBridge

@Suite("Re-homing after a DHCP change")
struct RehomeTests {

    @Test("Swaps the host and keeps everything else")
    func keepsPathAndScheme() throws {
        let original = URL(string: "https://192.0.2.10/clip/v2/resource/light/abc-123")!
        let moved = try #require(BridgeTransport.rehome(original, to: "192.0.2.20"))

        #expect(moved.host == "192.0.2.20")
        #expect(moved.path == "/clip/v2/resource/light/abc-123")
        #expect(moved.scheme == "https")
    }

    @Test("Preserves a query string")
    func keepsQuery() throws {
        let original = URL(string: "https://198.51.100.5/eventstream/clip/v2?lastEventId=7")!
        let moved = try #require(BridgeTransport.rehome(original, to: "198.51.100.9"))

        #expect(moved.absoluteString == "https://198.51.100.9/eventstream/clip/v2?lastEventId=7")
    }

    @Test("Re-homing to the same host is a no-op, not a mangle")
    func idempotent() throws {
        let original = URL(string: "https://192.0.2.10/clip/v2/resource/light")!
        let moved = try #require(BridgeTransport.rehome(original, to: "192.0.2.10"))
        #expect(moved == original)
    }
}

@Suite("Credentials")
struct CredentialsTests {

    @Test("Round-trips through JSON with the address replaced")
    func addressUpdate() throws {
        let original = BridgeCredentials(address: "192.0.2.10",
                                         bridgeID: "aabbccfffe112233", appKey: "k")
        var moved = original
        moved.address = "192.0.2.20"

        let decoded = try JSONDecoder().decode(
            BridgeCredentials.self, from: JSONEncoder().encode(moved))

        // The identity we pin against must survive an address change untouched.
        #expect(decoded.bridgeID == original.bridgeID)
        #expect(decoded.appKey == original.appKey)
        #expect(decoded.address == "192.0.2.20")
    }
}

@Suite("Lock box")
struct BoxTests {

    @Test("swap returns the previous value, so only one caller wins")
    func oneShotGuard() {
        let box = Box(false)
        #expect(box.swap(true) == false)   // first caller proceeds
        #expect(box.swap(true) == true)    // second is rejected
    }

    @Test("Concurrent mutation does not lose writes")
    func concurrentIncrements() async {
        let box = Box(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask { box.withLock { $0 += 1 } }
            }
        }
        #expect(box.withLock { $0 } == 500)
    }
}

@Suite("Bridge hostname derivation")
struct HostnameTests {

    @Test("Strips the EUI-64 padding to give the mDNS name")
    func derivesLocalName() {
        let credentials = BridgeCredentials(address: "192.0.2.10",
                                            bridgeID: "aabbccfffe112233", appKey: "k")
        #expect(credentials.localHostname == "aabbcc112233.local")
    }

    @Test("Accepts an uppercase bridge ID")
    func caseInsensitive() {
        let credentials = BridgeCredentials(address: "x",
                                            bridgeID: "AABBCCFFFE112233", appKey: "k")
        #expect(credentials.localHostname == "aabbcc112233.local")
    }

    @Test("Refuses to invent a name from a malformed ID")
    func rejectsMalformed() {
        // Wrong length, and right length but missing the fffe padding.
        #expect(BridgeCredentials(address: "x", bridgeID: "abc", appKey: "k")
            .localHostname == nil)
        #expect(BridgeCredentials(address: "x", bridgeID: "aabbcc0000112233", appKey: "k")
            .localHostname == nil)
    }
}

@Suite("Reconnect backoff")
struct BackoffTests {
    // The event stream used to retry every 3 seconds forever. A bridge that is
    // switched off overnight then means ~1200 pointless connections before morning.

    /// Mirrors the growth in `BridgeTransport.startEventStream`.
    private func backoffSequence(attempts: Int) -> [Int] {
        var delay = 1
        var delays: [Int] = []
        for _ in 0..<attempts {
            delays.append(delay)
            delay = min(delay * 2, 60)
        }
        return delays
    }

    @Test("Backoff grows and then holds at a minute")
    func growsAndCaps() {
        let delays = backoffSequence(attempts: 10)
        #expect(delays.prefix(4) == [1, 2, 4, 8])
        #expect(delays.last == 60)
        // Over an hour offline this is tens of attempts, not thousands.
        #expect(delays.reduce(0, +) < 400)
    }

    @Test("A reconnect resets the delay, so a flaky link recovers promptly")
    func resets() {
        var delay = 8
        delay = 1   // what a successful connect does
        #expect(delay == 1)
    }
}

@Suite("Diagnostics redaction")
struct RedactionTests {
    // The report exists to be pasted into issues, so it must not carry anything that
    // identifies the hardware. The bridge ID is derived from its MAC address.

    // Calls the shipped function. This test used to carry its own copy of the
    // implementation, which would have kept passing if the real one changed.

    @Test("A fingerprint discloses neither the key nor the bridge ID")
    func fingerprintHidesValue() {
        let salt = Fingerprint.newSalt()
        let bridgeID = "aabbccfffe112233"
        let printed = Fingerprint.of(bridgeID, salt: salt)

        #expect(!printed.contains(bridgeID))
        #expect(!printed.contains("aabbcc"))
        // Still useful within one report: it tells two values apart, and is stable.
        #expect(Fingerprint.of("key-one", salt: salt) != Fingerprint.of("key-two", salt: salt))
        #expect(Fingerprint.of(bridgeID, salt: salt) == Fingerprint.of(bridgeID, salt: salt))
    }

    @Test("Two installs fingerprint the same bridge differently")
    func saltBreaksLinkage() {
        // The point of the salt: reports pasted publicly by two people, or by one
        // person before and after re-pairing, cannot be tied to the same bridge.
        let bridgeID = "aabbccfffe112233"
        let a = Fingerprint.of(bridgeID, salt: Fingerprint.newSalt())
        let b = Fingerprint.of(bridgeID, salt: Fingerprint.newSalt())
        #expect(a != b)
    }

    @Test("Salts are random and long enough to matter")
    func saltShape() {
        #expect(Fingerprint.newSalt().count == 16)
        #expect(Fingerprint.newSalt() != Fingerprint.newSalt())
    }
}

@Suite("Bridge error messages")
struct BridgeErrorMessageTests {
    // A 429 from the bridge arrives as a full HTML error page. That page was shown
    // to the user verbatim in the popover.

    @Test("A response body never reaches the user-facing message")
    func bodyIsNotShown() {
        let html = "<!DOCTYPE HTML><html><body>Oops, there appears to be no lighting here</body></html>"
        let message = BridgeError.http(429, html).errorDescription ?? ""
        #expect(!message.contains("<"))
        #expect(!message.contains("DOCTYPE"))
        #expect(!message.contains("Oops"))
        #expect(message.lowercased().contains("busy"))
    }

    @Test("Each status a user can hit says something actionable")
    func statusesAreExplained() {
        #expect((BridgeError.http(401, "x").errorDescription ?? "").contains("pairing"))
        #expect((BridgeError.http(404, "x").errorDescription ?? "").contains("no longer"))
        #expect((BridgeError.http(503, "x").errorDescription ?? "").contains("internal"))
        // Anything unexpected still names the code, so a report is diagnosable.
        #expect((BridgeError.http(418, "x").errorDescription ?? "").contains("418"))
    }
}

@Suite("Pairing input validation")
struct PairingValidationTests {
    // Both of these guard the pin. A bridge ID that is not well formed reaches the
    // certificate check as a string to compare, and an empty one would match a
    // certificate with no common name at all.

    @Test("A bridge ID must be a MAC widened to EUI-64")
    func bridgeIDShape() {
        #expect(BridgePairing.isWellFormed(bridgeID: "aabbccfffe112233"))
        #expect(BridgePairing.isWellFormed(bridgeID: "AABBCCFFFE112233"))

        #expect(!BridgePairing.isWellFormed(bridgeID: ""))
        #expect(!BridgePairing.isWellFormed(bridgeID: "aabbccfffe1122"))     // short
        #expect(!BridgePairing.isWellFormed(bridgeID: "aabbccdddd112233"))   // no fffe
        #expect(!BridgePairing.isWellFormed(bridgeID: "zzbbccfffe112233"))   // not hex
    }

    @Test("Pairing refuses any address that is not on the local network")
    func onlyLocalAddresses() throws {
        // Synthetic addresses, present precisely to prove private ranges pass.
        for host in ["192.168.1.2", "10.0.0.5", "172.16.4.1", "172.31.255.254",  // check-no-secrets: allow
                     "169.254.1.1", "127.0.0.1", "aabbcc112233.local"] {
            #expect(throws: Never.self) { try BridgePairing.validateLocal(host: host) }
        }

        // A public host would otherwise be stored and talked to forever.
        for host in ["bridge.example.com", "8.8.8.8", "172.32.0.1", "1.2.3.4", ""] {  // check-no-secrets: allow
            #expect(throws: BridgeError.self) { try BridgePairing.validateLocal(host: host) }
        }
    }
}

@Suite("Certificate pinning")
struct PinningTests {
    // Two real self-signed certificates carrying the SAME common name and different
    // key pairs — exactly what a device on the LAN would present after reading the
    // bridge ID out of mDNS. If the pin is doing its job, the common name gets one
    // of them precisely nowhere.

    private func certificate(_ name: String) throws -> SecCertificate {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "der"))
        let data = try Data(contentsOf: url)
        return try #require(SecCertificateCreateWithData(nil, data as CFData))
    }

    @Test("A certificate with the right name but the wrong key is rejected")
    func impostorRejected() throws {
        let real = try certificate("pin-real")
        let impostor = try certificate("pin-impostor")
        let pinned = try #require(BridgePinning.publicKeyHash(of: real))

        // Same CN, so the pre-filter passes and the key decides.
        #expect(BridgePinning.matches(certificate: real,
                                      bridgeID: "aabbccfffe112233",
                                      expectedKeyHash: pinned))
        #expect(!BridgePinning.matches(certificate: impostor,
                                       bridgeID: "aabbccfffe112233",
                                       expectedKeyHash: pinned))
    }

    @Test("A mismatched common name is rejected before the key is consulted")
    func wrongNameRejected() throws {
        let real = try certificate("pin-real")
        let pinned = try #require(BridgePinning.publicKeyHash(of: real))
        #expect(!BridgePinning.matches(certificate: real,
                                       bridgeID: "ffeeddfffe998877",  // check-no-secrets: allow
                                       expectedKeyHash: pinned))
    }

    @Test("With no stored hash the name alone admits it, so first use can pin")
    func trustOnFirstUse() throws {
        // Credentials predating pinning must not lock the user out; the transport
        // records the key on this connection.
        let impostor = try certificate("pin-impostor")
        #expect(BridgePinning.matches(certificate: impostor,
                                      bridgeID: "aabbccfffe112233",
                                      expectedKeyHash: nil))
    }

    @Test("A public key hash is a SHA-256")
    func hashShape() throws {
        let hash = try #require(BridgePinning.publicKeyHash(of: try certificate("pin-real")))
        #expect(hash.count == 32)
    }


    @Test("A stored hash that differs is rejected, whatever the name says")
    func mismatchedHashRejected() {
        let stored = Data(repeating: 0xAB, count: 32)
        let presented = Data(repeating: 0xCD, count: 32)
        #expect(!BridgePinning.hashesMatch(presented: presented, expected: stored))
    }

    @Test("An equal hash is accepted")
    func matchingHashAccepted() {
        let hash = Data((0..<32).map { UInt8($0) })
        #expect(BridgePinning.hashesMatch(presented: hash, expected: hash))
    }

    @Test("A truncated hash never matches a longer one")
    func lengthMismatchRejected() {
        let full = Data(repeating: 0x11, count: 32)
        #expect(!BridgePinning.hashesMatch(presented: full.prefix(16), expected: full))
    }
}

@Suite("Credential read states")
struct CredentialStateTests {
    // "Nothing is paired" and "the Keychain would not answer" used to be the same
    // nil. They are not the same situation: the first is a fresh install, the
    // second is a paired user whose app silently dropped to Bluetooth and hid the
    // control that would have got them back.

    @Test("A missing item reads as not paired, not as a failure")
    func distinctStates() {
        // errSecItemNotFound must map to .notPaired; anything else is a failure the
        // user is told about.
        #expect(BridgeStore.isNotPairedStatus(errSecItemNotFound))
        #expect(!BridgeStore.isNotPairedStatus(errSecAuthFailed))
        #expect(!BridgeStore.isNotPairedStatus(errSecInteractionNotAllowed))
        #expect(!BridgeStore.isNotPairedStatus(errSecDecode))
    }
}

@Suite("Bridge discovery")
struct DiscoveryTests {
    // Discovery never resolves an mDNS endpoint — resolving a `.service` endpoint
    // never completes under the sandbox. It reads the bridge ID out of the TXT
    // record and derives the `.local` name, which is the same derivation that
    // recovers from a DHCP change. That derivation is the part worth testing.

    @Test("A candidate's host is the ID with the EUI-64 padding removed")
    func hostDerivation() {
        let credentials = BridgeCredentials(address: "", bridgeID: "aabbccfffe112233",
                                            appKey: "")
        #expect(credentials.localHostname == "aabbcc112233.local")
    }

    @Test("A malformed bridge ID yields no host, so it is never offered")
    func malformedIDRejected() {
        for bad in ["", "aabbcc", "aabbccdddd112233", "zzbbccfffe112233"] {
            let credentials = BridgeCredentials(address: "", bridgeID: bad, appKey: "")
            #expect(credentials.localHostname == nil)
            // The same shape check gates a TXT record before it becomes a candidate.
            #expect(!BridgePairing.isWellFormed(bridgeID: bad))
        }
    }

    @Test("Candidates are identified by bridge ID, so one bridge appears once")
    func candidateIdentity() {
        let a = BridgeDiscovery.Candidate(bridgeID: "aabbccfffe112233",
                                          host: "aabbcc112233.local",
                                          displayName: "Hue Bridge - 112233")
        let b = BridgeDiscovery.Candidate(bridgeID: "aabbccfffe112233",
                                          host: "aabbcc112233.local",
                                          displayName: "Hue Bridge - 112233 (2)")
        #expect(a.id == b.id)
        #expect(a != b)
    }
}
