// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import VestaKit

/// One-time pairing with a Hue Bridge.
///
/// Trust-on-first-use. During pairing there is nothing to pin against yet, so the
/// certificate is accepted and its public key recorded. The user is physically
/// pressing a button on the device at that moment, which is the strongest
/// authorisation available. Every later connection is pinned to that key — see
/// `BridgePinning` and `BridgeTransport`'s TLS handling.
public final class BridgePairing: NSObject, @unchecked Sendable {

    private var session: URLSession!
    /// The public key of whatever answered during this pairing, captured by the TLS
    /// delegate so it can be pinned afterwards.
    private let observedKeyHash = Box<Data?>(nil)

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Reads the bridge's unauthenticated config — proves we are talking to a
    /// bridge and gives us the ID it claims.
    public func identify(host: String) async throws -> String {
        try BridgePairing.validateLocal(host: host)
        guard let url = URL(string: "https://\(host)/api/config") else {
            throw BridgeError.notFound
        }
        let (data, _) = try await session.data(from: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bridgeID = object["bridgeid"] as? String,
              BridgePairing.isWellFormed(bridgeID: bridgeID) else {
            throw BridgeError.malformedResponse
        }
        return bridgeID.lowercased()
    }

    /// Refuses to pair with anything off the local network.
    ///
    /// Nothing else constrains the address: it arrives from the command line, is
    /// stored, and is used forever after. A user talked into pairing with a public
    /// host would have an app that faithfully reports their home to it.
    static func validateLocal(host: String) throws {
        let name = host.lowercased()
        if name.hasSuffix(".local") { return }

        let parts = name.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { throw BridgeError.notLocalAddress }
        let isPrivate = parts[0] == 10
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
            || parts[0] == 127
        guard isPrivate else { throw BridgeError.notLocalAddress }
    }

    /// A bridge ID is a MAC widened to EUI-64: 16 hex characters with `fffe` in the
    /// middle. An empty or arbitrary string must never reach the pin.
    static func isWellFormed(bridgeID: String) -> Bool {
        let id = bridgeID.lowercased()
        return id.count == 16
            && id.allSatisfy { $0.isHexDigit }
            && id.dropFirst(6).prefix(4) == "fffe"
    }

    /// Polls until the link button is pressed or the deadline passes.
    public func pair(host: String, bridgeID: String,
                     timeout: Duration = .seconds(60),
                     onWaiting: @Sendable (Int) -> Void = { _ in }) async throws -> BridgeCredentials {
        try BridgePairing.validateLocal(host: host)
        guard let url = URL(string: "https://\(host)/api") else {
            throw BridgeError.notFound
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "devicetype": "vesta#mac", "generateclientkey": true,
        ])

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var attempt = 0

        while ContinuousClock.now < deadline {
            attempt += 1
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (data, _) = try await session.data(for: request)
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = array.first {
                if let success = first["success"] as? [String: Any],
                   let key = success["username"] as? String {
                    // Pin the key of whatever we just pressed a button on.
                    return BridgeCredentials(address: host, bridgeID: bridgeID,
                                             appKey: key,
                                             publicKeyHash: observedKeyHash.withLock { $0 },
                                             fingerprintSalt: Fingerprint.newSalt())
                }
                if let error = first["error"] as? [String: Any],
                   let type = error["type"] as? Int, type == 101 {
                    onWaiting(attempt)
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                throw BridgeError.http(200, String(describing: first))
            }
            throw BridgeError.malformedResponse
        }
        throw BridgeError.linkButtonNotPressed
    }
}

extension BridgePairing: URLSessionDelegate {
    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Deliberately permissive, and only here: there is nothing to pin against
        // until this exchange completes. The key is recorded so that everything
        // afterwards can be pinned to it.
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if let leaf = BridgePinning.leafCertificate(from: trust) {
            observedKeyHash.withLock { $0 = BridgePinning.publicKeyHash(of: leaf) }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
