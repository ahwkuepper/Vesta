// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A fake set of bulbs that behaves like real ones, including badly.
///
/// This is not throwaway scaffolding. It is the only way to test the app
/// deterministically — you cannot write a reliable regression test against a
/// physical bulb that someone might have switched off at the wall. It also lets the
/// whole UI be built and demonstrated while BLE bonding is unresolved.
public actor SimulatedTransport: LightTransport {

    /// Fault injection, so the nasty paths get exercised instead of assumed away.
    public struct Faults: Sendable {
        /// Simulated round-trip latency, matching observed BLE write latency.
        public var latency: Duration = .milliseconds(80)
        /// Fraction of writes that fail outright.
        public var writeFailureRate: Double = 0
        /// These lights refuse all commands, as an unbonded bulb would.
        public var needsPairing: Set<Light.ID> = []
        /// These lights are out of range.
        public var unreachable: Set<Light.ID> = []

        public init() {}
    }

    private var lights: [Light.ID: Light] = [:]
    private var rooms: [Room] = SimulatedTransport.demoRooms
    private var scenes: [RoomScene] = []
    private var handler: (@MainActor (TransportEvent) -> Void)?
    public var faults = Faults()

    public init(lights: [Light] = SimulatedTransport.demoLights) {
        self.lights = Dictionary(uniqueKeysWithValues: lights.map { ($0.id, $0) })
    }

    public func setFaults(_ f: Faults) { faults = f }

    /// Mirrors the two real bulbs on this desk, so the simulator and the room agree.
    public static var demoLights: [Light] {
        [
            Light(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                  name: "Desk lamp", model: "LCB002",
                  state: LightState(isOn: true, brightness: 0.72, color: .temperature(mireds: 366)),
                  connection: .ready, rssi: -45),
            Light(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                  name: "Corner lamp", model: "LCB002",
                  state: LightState(isOn: true, brightness: 0.45, color: .xy(x: 0.52, y: 0.32)),
                  connection: .ready, rssi: -48,
                  capabilities: LightCapabilities(
                    gradientPoints: 5,
                    effects: ["candle", "fire", "prism", "sparkle", "opal"])),
        ]
    }

    /// Mirrors the real bridge's rooms so tests and snapshots match the room this
    /// app is actually used in.
    public static var demoRooms: [Room] {
        let ids = demoLights.map(\.id)
        return [
            Room(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                 name: "Office", archetype: "office",
                 lightIDs: ids, groupedLightID: UUID()),
        ]
    }

    public func setGradient(_ gradient: LightGradient, for id: Light.ID) async throws {
        guard let first = gradient.points.first else { return }
        try await mutate(id) { $0.color = first }
    }

    public func setEffect(_ effect: String?, for id: Light.ID) async throws {
        guard lights[id] != nil else { throw TransportError.unknownLight }
    }

    public func fetchLights() async throws -> [Light] {
        lights.values.sorted { $0.name < $1.name }
    }

    public func fetchRooms() async throws -> [Room] { rooms }
    public func fetchScenes() async throws -> [RoomScene] { scenes }

    public func recallScene(_ id: RoomScene.ID) async throws {
        guard scenes.contains(where: { $0.id == id }) else { throw TransportError.unknownLight }
        for key in lights.keys {
            lights[key]?.state.isOn = true
        }
    }

    public func createScene(named name: String, in room: Room.ID,
                            actions: [SceneAction] = []) async throws -> RoomScene {
        let scene = RoomScene(id: UUID(), name: name, roomID: room, isEditable: true)
        scenes.append(scene)
        return scene
    }

    public func deleteScene(_ id: RoomScene.ID) async throws {
        guard scenes.contains(where: { $0.id == id }) else { throw TransportError.unknownLight }
        scenes.removeAll { $0.id == id }
    }

    public func start(handler: @escaping @MainActor (TransportEvent) -> Void) async {
        self.handler = handler
        await emit(.availabilityChanged(.ready))
        // Stagger discovery so the UI's appearance animations get exercised rather
        // than everything popping in on the same frame.
        for light in lights.values.sorted(by: { $0.name < $1.name }) {
            try? await Task.sleep(for: .milliseconds(120))
            await emit(.discovered(light))
        }
    }

    public func stop() async { handler = nil }

    public func setPower(_ on: Bool, for id: Light.ID) async throws {
        try await mutate(id) { $0.isOn = on }
    }

    public func setBrightness(_ brightness: Double, for id: Light.ID) async throws {
        try await mutate(id) { $0.brightness = brightness.clamped(to: 0...1) }
    }

    public func setColor(_ color: LightColor, for id: Light.ID) async throws {
        try await mutate(id) { $0.color = color }
    }

    private func mutate(_ id: Light.ID, _ change: (inout LightState) -> Void) async throws {
        guard var light = lights[id] else { throw TransportError.unknownLight }
        if faults.needsPairing.contains(id) { throw TransportError.needsPairing }
        if faults.unreachable.contains(id) { throw TransportError.notConnected }

        try? await Task.sleep(for: faults.latency)

        if faults.writeFailureRate > 0, Double.random(in: 0...1) < faults.writeFailureRate {
            throw TransportError.writeFailed("The light did not respond.")
        }

        change(&light.state)
        lights[id] = light
        // Report back the way a real bulb does — via a state notification, not as
        // the return value of the write.
        await emit(.stateChanged(id: id, delta: LightStateDelta(light.state)))
    }

    private func emit(_ event: TransportEvent) async {
        guard let handler else { return }
        await MainActor.run { handler(event) }
    }
}
