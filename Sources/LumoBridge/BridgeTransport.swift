import Foundation
import Security
import LumoKit

/// Talks to a Hue Bridge over the local CLIP v2 API.
///
/// Conforms to the same `LightTransport` as `BLETransport`. Unlike BLE it needs no
/// bond, has no range limit or ten-bulb ceiling, and reports state changes made from
/// anywhere — the Hue app, a dimmer switch, a routine.
public final class BridgeTransport: NSObject, LightTransport, @unchecked Sendable {

    /// Mutable: the bridge's address changes when its DHCP lease does, and the
    /// transport re-homes itself rather than failing until the user re-pairs.
    private let state: Box<BridgeCredentials>
    private var session: URLSession!
    /// Separate session for the event stream. `timeoutIntervalForResource` is a
    /// ceiling on a whole transfer, and the stream is a response that never
    /// finishes — so it needs `.infinity`, and ordinary requests must not share it.
    private var streamSession: URLSession!
    /// Serialises relocation so a burst of failed requests triggers one search.
    private let relocating = Box(false)
    /// Ceiling on a single response body. The largest real CLIP v2 payload on a
    /// large installation is a few hundred kilobytes.
    static let maximumResponseBytes = 8 * 1024 * 1024

    public var credentials: BridgeCredentials { state.withLock { $0 } }
    private var handler: (@MainActor (TransportEvent) -> Void)?
    private var eventTask: Task<Void, Never>?

    public init(credentials: BridgeCredentials) {
        self.state = Box(credentials)
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        // Bounded: `timeoutIntervalForRequest` only measures inactivity, so a host
        // dribbling one byte every nine seconds holds a request open forever.
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.timeoutIntervalForRequest = 0
        streamConfig.timeoutIntervalForResource = .infinity
        streamSession = URLSession(configuration: streamConfig, delegate: self,
                                   delegateQueue: nil)
    }

    var base: URL {
        URL(string: "https://\(credentials.address)/clip/v2/resource")!
    }

    /// Streams raw server-sent event payloads, for diagnosing what the bridge
    /// actually pushes after a scene recall.
    public func watchRawEvents(seconds: Double, onLine: @escaping @Sendable (String) -> Void) async {
        let url = URL(string: "https://\(credentials.address)/eventstream/clip/v2")!
        var streamRequest = request(url)
        streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let deadline = Date().addingTimeInterval(seconds)
        let task = Task {
            guard let (bytes, _) = try? await streamSession.bytes(for: streamRequest) else { return }
            for try await line in bytes.lines {
                if Date() > deadline || Task.isCancelled { return }
                if line.hasPrefix("data: ") { onLine(String(line.dropFirst(6))) }
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
    }

    /// Raw JSON for any CLIP v2 resource type, for exploring what a bridge exposes.
    public func rawResource(_ type: String) async throws -> String {
        let (data, _) = try await send(request(base.appendingPathComponent(type)))
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A single cheap request, used to test whether an address is really the bridge.
    /// Pinning does the identity check, so success here means "this is our bridge".
    public func probe() async -> Bool {
        defer { session.invalidateAndCancel() }
        return (try? await loadLights(attempts: 2)) != nil
    }

    /// macOS evaluates local-network permission asynchronously, so the first
    /// connection after a cold launch can fail with "not connected to the
    /// internet" (-1009) while that check is still in flight — even though the
    /// permission is granted and the next attempt succeeds. Retry those, and the
    /// ordinary transient network errors, rather than surfacing a wrong diagnosis.
    func send(_ request: URLRequest, attempts: Int = 4,
                      allowRelocate: Bool = true) async throws -> (Data, URLResponse) {
        var lastError: Error = BridgeError.malformedResponse
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(for: request)
        // A bridge answer is a few kilobytes; anything approaching this is either
        // broken or hostile, and `data(for:)` buffers all of it in memory.
        guard data.count <= Self.maximumResponseBytes else {
            throw BridgeError.malformedResponse
        }
                // 429 is the bridge asking for less, not an error to show anyone.
                // Hue rate-limits light commands; back off and try again.
                if let http = response as? HTTPURLResponse, http.statusCode == 429,
                   attempt < attempts - 1 {
                    Log.transport.debug("bridge returned 429, backing off")
                    try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                    continue
                }
                return (data, response)
            } catch {
                lastError = error
                let code = (error as NSError).code
                let retryable = [NSURLErrorNotConnectedToInternet,
                                 NSURLErrorNetworkConnectionLost,
                                 NSURLErrorCannotConnectToHost,
                                 NSURLErrorTimedOut]
                guard retryable.contains(code), attempt < attempts - 1 else { break }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }

        // Exhausted retries against this address. It may simply be the wrong one
        // now, so look the bridge up again and replay the request once.
        if allowRelocate, isAddressFailure(lastError), await relocate() {
            return try await send(rehomed(request), attempts: 2, allowRelocate: false)
        }
        throw lastError
    }

    private func isAddressFailure(_ error: Error) -> Bool {
        [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
         NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
         NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed,
         NSURLErrorServerCertificateUntrusted]
            .contains((error as NSError).code)
    }

    /// Points a request at the current address, preserving path, method and body.
    private func rehomed(_ request: URLRequest) -> URLRequest {
        guard let old = request.url,
              let new = Self.rehome(old, to: credentials.address) else { return request }
        var updated = request
        updated.url = new
        return updated
    }

    /// Swaps only the host, keeping scheme, path and query intact.
    static func rehome(_ url: URL, to host: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.host = host
        return components.url
    }

    private func relocate() async -> Bool {
        // Only one search at a time; concurrent callers reuse whatever it finds.
        if relocating.swap(true) {
            while relocating.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            return true
        }
        defer { _ = relocating.swap(false) }

        let current = credentials
        guard let found = await BridgeLocator.locate(current, verifyCurrentFirst: false),
              found.address != current.address
        else { return false }

        state.withLock { $0 = found }
        return true
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.appKey, forHTTPHeaderField: "hue-application-key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - LightTransport

    public func start(handler: @escaping @MainActor (TransportEvent) -> Void) async {
        self.handler = handler
        do {
            let lights = try await fetchLights()
            await emit(.availabilityChanged(.ready))
            for light in lights {
                await emit(.discovered(light))
                await emit(.stateChanged(id: light.id, delta: LightStateDelta(light.state)))
            }
            startEventStream()
        } catch {
            await emit(.availabilityChanged(.unsupported))
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        session.invalidateAndCancel()
    }

    /// Every light the bridge knows about, with its current state.
    public func fetchLights() async throws -> [Light] {
        try await loadLights(attempts: 4)
    }

    func loadLights(attempts: Int) async throws -> [Light] {
        let (data, response) = try await send(request(base.appendingPathComponent("light")),
                                              attempts: attempts)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            // The key was revoked — almost always because the entry was deleted from
            // the Hue app. Saying "403" helps nobody; this is re-pairable.
            Log.transport.error("bridge rejected our key (HTTP \(http.statusCode))")
            throw TransportError.unauthorized
        }
        guard http.statusCode == 200 else {
            throw BridgeError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try BridgeCoding.lights(from: data)
    }

    public func setPower(_ on: Bool, for id: Light.ID) async throws {
        try await put(["on": ["on": on]], to: id)
    }

    public func setBrightness(_ brightness: Double, for id: Light.ID) async throws {
        // CLIP v2 dimming is 0…100, and 0 is rejected — off is the `on` resource's job.
        let percent = max(1.0, min(100.0, brightness * 100))
        try await put(["dimming": ["brightness": percent]], to: id)
    }

    /// Gradient points are xy only — the bridge rejects mireds inside a gradient,
    /// so a colour temperature is converted to its xy equivalent first.
    public func setGradient(_ gradient: LightGradient, for id: Light.ID) async throws {
        let points: [[String: Any]] = gradient.points.map { color in
            let xy: (x: Double, y: Double)
            switch color {
            case .xy(let x, let y):
                xy = (x, y)
            case .temperature(let mireds):
                xy = ColorScience.xy(fromRGB: ColorScience.rgb(fromMireds: mireds))
            }
            return ["color": ["xy": ["x": xy.x, "y": xy.y]]]
        }
        try await put(["gradient": ["points": points, "mode": gradient.mode]],
                      to: "light/\(id.uuidString.lowercased())")
    }

    public func setEffect(_ effect: String?, for id: Light.ID) async throws {
        try await put(["effects_v2": ["action": ["effect": effect ?? "no_effect"]]],
                      to: "light/\(id.uuidString.lowercased())")
    }

    public func setColor(_ color: LightColor, for id: Light.ID) async throws {
        switch color {
        case .temperature(let mireds):
            try await put(["color_temperature": ["mirek": mireds]], to: id)
        case .xy(let x, let y):
            try await put(["color": ["xy": ["x": x, "y": y]]], to: id)
        }
    }

    private func put(_ body: [String: Any], to id: Light.ID) async throws {
        let url = base.appendingPathComponent("light/\(id.uuidString.lowercased())")
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await send(request(url, method: "PUT", body: data))
        guard let http = response as? HTTPURLResponse else { throw BridgeError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(http.statusCode, String(data: responseData, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Event stream

    /// Server-sent events, so state stays correct when someone uses the Hue app or
    /// a wall dimmer. This is what BLE `notify` was for, without the bond.
    private func startEventStream() {
        let url = URL(string: "https://\(credentials.address)/eventstream/clip/v2")!
        var streamRequest = request(url)
        streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        eventTask = Task { [weak self] in
            guard let self else { return }
            var backoff = 1
            while !Task.isCancelled {
                do {
                    let (bytes, _) = try await streamSession.bytes(for: streamRequest)
                    backoff = 1
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        await handleEvent(payload)
                    }
                    // A clean end of stream is normal; reset the backoff.
                    backoff = 1
                } catch {
                    guard !Task.isCancelled else { return }
                    // The bridge drops the stream periodically, so reconnecting is
                    // routine — but a bridge that is off, unplugged or renumbered
                    // must not be retried every 3 seconds for the rest of the week.
                    // Exponential up to a minute, reset on any successful connect.
                    Log.transport.debug("event stream reconnecting in \(backoff)s")
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 60)
                }
            }
        }
    }

    private func handleEvent(_ json: String) async {
        guard let data = json.data(using: .utf8) else { return }
        for update in BridgeCoding.deltas(fromEvent: data) {
            await emit(.stateChanged(id: update.id, delta: update.delta))
        }
    }

    private func emit(_ event: TransportEvent) async {
        guard let handler else { return }
        await MainActor.run { handler(event) }
    }
}

// MARK: - TLS

extension BridgeTransport: URLSessionDelegate {
    /// Accepts exactly the bridge we paired with.
    ///
    /// Hue Bridges present a self-signed certificate, so there is no chain to
    /// validate — identity comes from the public key recorded at pairing. The
    /// common name is checked first because it is cheap, but it decides nothing:
    /// the bridge ID is published in mDNS and returned unauthenticated by
    /// `/api/config`, so any device on the network can present a certificate
    /// bearing it. Only the key pair cannot be forged.
    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?) {

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = BridgePinning.leafCertificate(from: trust)
        else { return (.cancelAuthenticationChallenge, nil) }

        let current = credentials
        guard BridgePinning.matches(certificate: leaf,
                                    bridgeID: current.bridgeID,
                                    expectedKeyHash: current.publicKeyHash) else {
            Log.transport.error("rejected a certificate that is not the paired bridge")
            return (.cancelAuthenticationChallenge, nil)
        }

        // Credentials stored before pinning existed carry no hash. Record it now,
        // so this is trust-on-first-use once rather than a permanent hole.
        if current.publicKeyHash == nil,
           let hash = BridgePinning.publicKeyHash(of: leaf) {
            state.withLock { $0.publicKeyHash = hash }
            try? BridgeStore.save(credentials)
            Log.transport.info("pinned the bridge's public key")
        }

        return (.useCredential, URLCredential(trust: trust))
    }
}
