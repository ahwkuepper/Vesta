// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import VestaKit

/// Finds a Hue Bridge on the network before anything is paired.
///
/// `BridgeLocator` cannot help here: it re-finds a bridge whose ID is already known,
/// by deriving the `.local` name from that ID. On a first run there is no ID.
///
/// Browsing for `_hue._tcp` returns endpoints, but resolving one to an address never
/// completes under the app sandbox — `NWConnection` to a `.service` endpoint stays in
/// `.preparing` indefinitely. So this never resolves. A bridge publishes its ID in
/// the TXT record of its Bonjour advertisement, and the `.local` name derives from
/// that ID the same way it does after pairing. Browse, read the TXT, derive the name,
/// and let mDNS do the resolution as part of an ordinary connection.
///
/// Identity is not established here and cannot be: nothing is paired yet, so there is
/// no key to pin against. Discovery only proposes a candidate; the button press on
/// the physical bridge is what authorises it, and the key recorded during that
/// exchange is what every later connection is pinned to.
public enum BridgeDiscovery {

    public struct Candidate: Sendable, Equatable, Identifiable {
        /// The bridge ID from the TXT record, lowercased.
        public let bridgeID: String
        /// The derived `<id>.local` name, which is what to connect to.
        public let host: String
        /// The advertised Bonjour name, for showing a person which bridge this is.
        public let displayName: String

        public var id: String { bridgeID }

        public init(bridgeID: String, host: String, displayName: String) {
            self.bridgeID = bridgeID
            self.host = host
            self.displayName = displayName
        }
    }

    /// Browses for bridges, returning any that answer as one.
    ///
    /// Candidates are confirmed by an unauthenticated `/api/config` read, so a stale
    /// mDNS advertisement for a bridge that has gone away is not offered to the user.
    public static func find(timeout: Duration = .seconds(5)) async -> [Candidate] {
        let advertised = await browse(timeout: timeout)
        guard !advertised.isEmpty else { return [] }

        var confirmed: [Candidate] = []
        let pairing = BridgePairing()
        for candidate in advertised {
            // Confirms it is reachable and really is the bridge it advertised.
            guard let reported = try? await pairing.identify(host: candidate.host),
                  reported == candidate.bridgeID else { continue }
            confirmed.append(candidate)
        }
        return confirmed
    }

    /// One browse pass. Returns as soon as the timeout elapses — Bonjour has no
    /// "that is all of them" signal, so waiting is the only way to be reasonably sure.
    private static func browse(timeout: Duration) async -> [Candidate] {
        await withCheckedContinuation { continuation in
            let found = Box<[String: Candidate]>([:])
            let finished = Box(false)

            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil),
                using: parameters)

            @Sendable func finish() {
                let alreadyDone = finished.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadyDone else { return }
                browser.cancel()
                continuation.resume(returning: Array(found.withLock { $0 }.values))
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let txt) = result.metadata,
                          let rawID = txt["bridgeid"] ?? txt["bridgeId"],
                          BridgePairing.isWellFormed(bridgeID: rawID) else { continue }

                    let bridgeID = rawID.lowercased()
                    // The same EUI-64 unpadding used to recover from a DHCP change.
                    guard let host = BridgeCredentials(
                            address: "", bridgeID: bridgeID, appKey: "").localHostname
                    else { continue }

                    let name: String
                    if case .service(let service, _, _, _) = result.endpoint {
                        name = service
                    } else {
                        name = "Hue Bridge"
                    }
                    found.withLock {
                        $0[bridgeID] = Candidate(bridgeID: bridgeID, host: host,
                                                 displayName: name)
                    }
                }
            }

            browser.stateUpdateHandler = { state in
                // A browser that cannot start — local network permission refused, for
                // instance — must not leave the caller waiting for the full timeout.
                if case .failed = state { finish() }
            }

            browser.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }
}
