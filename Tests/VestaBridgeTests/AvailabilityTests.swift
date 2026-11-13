import Foundation
import Testing
import VestaKit
@testable import VestaBridge

private final class AvailabilityHTTP: URLProtocol, @unchecked Sendable {
    struct State {
        var statuses: [Int] = []
        var lights = Data()
        var streams = 0
    }
    static let state = Box(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/eventstream/clip/v2" {
            Self.state.withLock { $0.streams += 1 }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(": keepalive\n\n".utf8))
            // Hold the stream until transport.stop(), without any real network traffic.
            return
        }
        let (status, data) = Self.state.withLock { state -> (Int, Data) in
            guard url.path.hasSuffix("/light") else { return (200, Data(#"{"data":[]}"#.utf8)) }
            return (state.statuses.isEmpty ? 200 : state.statuses.removeFirst(), state.lights)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                                                              httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 200 ? data : Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Hue availability recovery", .serialized) @MainActor
struct AvailabilityTests {
    private func transport(statuses: [Int]) throws -> BridgeTransport {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/lights", withExtension: "json"))
        let data = try Data(contentsOf: url)
        AvailabilityHTTP.state.withLock { $0 = .init(statuses: statuses, lights: data) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvailabilityHTTP.self]
        return BridgeTransport(credentials: BridgeCredentials(address: "192.0.2.10", bridgeID: "aabbccfffe112233", appKey: "k"),
                               configuration: config, streamConfiguration: config)
    }
    @Test func startupFailureRecoversStatusAndStartsExactlyOneEventStream() async throws {
        let transport = try transport(statuses: [503, 200, 200])
        var states: [TransportAvailability] = []
        await transport.start { if case .availabilityChanged(let value) = $0 { states.append(value) } }
        #expect(states == [.bridgeUnavailable])
        #expect(AvailabilityHTTP.state.withLock { $0.streams } == 0)
        #expect(TransportAvailability.bridgeUnavailable.message?.contains("Bluetooth") == false)
        _ = try await transport.fetchLights()
        _ = try await transport.fetchLights()
        #expect(states.last == .ready)
        for _ in 0..<50 {
            if AvailabilityHTTP.state.withLock({ $0.streams }) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(AvailabilityHTTP.state.withLock { $0.streams } == 1)
        await transport.stop()
    }
    @Test func storeResyncClearsTheStartupWarningWithoutLosingLights() async throws {
        let transport = try transport(statuses: [503, 200, 503, 200])
        let store = LightStore(transport: transport)
        await store.start() // Includes a resync after the initial failure.
        #expect(store.availability == .ready)
        #expect(store.lights.count == 3)
        await store.resync()
        #expect(store.availability == .bridgeUnavailable)
        #expect(store.lights.count == 3)
        await store.resync()
        #expect(store.availability == .ready)
        #expect(store.availability.message == nil)
        await store.stop()
    }
    @Test func rejectedPairingNeverSuggestsBluetoothPermission() async throws {
        let transport = try transport(statuses: [403])
        var states: [TransportAvailability] = []
        await transport.start { if case .availabilityChanged(let value) = $0 { states.append(value) } }
        #expect(states == [.credentialsRejected])
        #expect(AvailabilityHTTP.state.withLock { $0.streams } == 0)
        await transport.stop()
    }
}
