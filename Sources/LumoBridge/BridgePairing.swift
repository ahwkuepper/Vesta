import Foundation

/// One-time pairing with a Hue Bridge.
///
/// Trust-on-first-use: during pairing we cannot yet pin the bridge's certificate,
/// because the bridge ID we would pin against is what we are fetching. The user is
/// physically pressing a button on the device at that moment, which is the strongest
/// authorisation available. After pairing we store the bridge ID and every later
/// connection is pinned to it — see `BridgeTransport`'s TLS handling.
public final class BridgePairing: NSObject, @unchecked Sendable {

    private var session: URLSession!

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Reads the bridge's unauthenticated config — proves we are talking to a
    /// bridge and gives us the ID to pin against later.
    public func identify(host: String) async throws -> String {
        let url = URL(string: "https://\(host)/api/config")!
        let (data, _) = try await session.data(from: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bridgeID = object["bridgeid"] as? String else {
            throw BridgeError.malformedResponse
        }
        return bridgeID.lowercased()
    }

    /// Polls until the link button is pressed or the deadline passes.
    public func pair(host: String, bridgeID: String,
                     timeout: Duration = .seconds(60),
                     onWaiting: @Sendable (Int) -> Void = { _ in }) async throws -> BridgeCredentials {
        let url = URL(string: "https://\(host)/api")!
        let body = try JSONSerialization.data(withJSONObject: [
            "devicetype": "lumo#mac", "generateclientkey": true,
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
                    return BridgeCredentials(address: host, bridgeID: bridgeID, appKey: key)
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
        // Deliberately permissive, and only here. See the note on this type.
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
