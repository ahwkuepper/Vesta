import Foundation
import Observation

/// The single source of truth the UI observes.
///
/// Writes are optimistic: the local model moves the instant the user does, and is
/// reconciled from the bridge's own event stream afterwards. Waiting for a network
/// round-trip before the slider moves feels broken, and no animation hides it.
@MainActor
@Observable
public final class LightStore {

    public private(set) var lights: [Light] = []
    public private(set) var rooms: [Room] = []
    public private(set) var scenes: [RoomScene] = []
    public private(set) var availability: TransportAvailability = .ready
    /// When the model was last confirmed against the transport, and when the
    /// transport last pushed anything. Together they distinguish "quiet because
    /// nothing changed" from "quiet because the connection died" — which otherwise
    /// look identical and are the failure people notice weeks later.
    public private(set) var lastSyncAt: Date?
    public private(set) var lastEventAt: Date?
    /// The most recent failure worth telling the user about, shown as a banner and
    /// cleared automatically. Every failure path sets this — silently swallowing
    /// them is what made the app look broken when a write was refused.
    public var lastError: UserFacingError?

    private var errorDismissal: Task<Void, Never>?

    /// Records a failure, logs it, and schedules the banner to clear itself.
    func report(_ action: String, _ error: Error) {
        let reason = error.localizedDescription
        Log.store.error("\(action, privacy: .public) failed: \(reason, privacy: .public)")
        lastError = UserFacingError(action: action, reason: reason)
        errorDismissal?.cancel()
        errorDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    public func dismissError() {
        errorDismissal?.cancel()
        lastError = nil
    }

    private let transport: LightTransport
    /// One in-flight write per light per property; newer values supersede queued
    /// ones. Sending every intermediate value of a drag saturates the connection
    /// and the UI visibly lags the thumb.
    /// The newest unsent value per light and property, and the loop draining it.
    private var latestWrite: [WriteKey: @Sendable () async throws -> Void] = [:]
    private var writeLoop: [WriteKey: Task<Void, Never>] = [:]
    /// Scene recalls are coalesced; see `recall(_:)`.
    private var pendingRecall: Task<Void, Never>?
    private var recallGeneration = 0

    private struct WriteKey: Hashable {
        let light: UUID
        let property: Property
        enum Property: Hashable { case power, brightness, color }
    }

    public init(transport: LightTransport,
                initialLights: [Light] = [],
                initialRooms: [Room] = [],
                initialScenes: [RoomScene] = []) {
        self.transport = transport
        self.lights = initialLights
        self.rooms = initialRooms
        self.scenes = initialScenes
    }

    // MARK: - Lifecycle

    public func start() async {
        await transport.start { [weak self] event in
            self?.handle(event)
        }
        await refreshRoomsAndScenes()
        // Confirm wholesale even though the transport has just delivered state.
        // Without this `lastSyncAt` stays nil for the whole session and the health
        // report says "last sync never" while the model is perfectly current — the
        // opposite of what a health check is for.
        await resync()
    }

    /// Re-reads the truth from the transport and adopts it wholesale.
    ///
    /// Called after anything that could have left the local model out of step: a
    /// failed write, a rejected room switch, a scene recall, and whenever the
    /// popover opens. The lights are shared with the Hue app, wall switches and
    /// routines, so the local model is a cache and must never be trusted after an
    /// error.
    public func resync() async {
        guard let fetched = try? await transport.fetchLights(), !fetched.isEmpty else { return }
        for light in fetched {
            if let i = lights.firstIndex(where: { $0.id == light.id }) {
                lights[i].state = light.state
                lights[i].connection = light.connection
                lights[i].capabilities = light.capabilities
            } else {
                lights.append(light)
            }
        }
        lights.sort { $0.name < $1.name }
        lastSyncAt = .now
        Log.store.debug("resync: \(self.lights.count) lights")
    }

    public func refreshRoomsAndScenes() async {
        if let fetched = try? await transport.fetchRooms() { rooms = fetched }
        if let fetched = try? await transport.fetchScenes() { scenes = fetched }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .discovered(let light):
            if let i = lights.firstIndex(where: { $0.id == light.id }) {
                // Preserve locally-known state; a rediscovery should not stomp it.
                lights[i].name = light.name
                lights[i].model = light.model
                lights[i].rssi = light.rssi
                lights[i].connection = light.connection
            } else {
                lights.append(light)
                lights.sort { $0.name < $1.name }
            }

        case .stateChanged(let id, let delta):
            lastEventAt = .now
            guard let i = lights.firstIndex(where: { $0.id == id }) else { return }
            lights[i].state = delta.applied(to: lights[i].state)

        case .connectionChanged(let id, let connection):
            guard let i = lights.firstIndex(where: { $0.id == id }) else { return }
            lights[i].connection = connection

        case .availabilityChanged(let a):
            availability = a
        }
    }

    // MARK: - Derived state

    public var anyLightOn: Bool {
        lights.contains { $0.state.isOn && $0.connection.isCommandable }
    }

    public var commandableLights: [Light] {
        lights.filter { $0.connection.isCommandable }
    }

    /// True when we can see bulbs but cannot command any of them.
    public var allLightsNeedPairing: Bool {
        !lights.isEmpty && lights.allSatisfy { $0.connection == .needsPairing }
    }

    public func lights(in room: Room) -> [Light] {
        room.lightIDs.compactMap { id in lights.first { $0.id == id } }
    }

    public func scenes(in room: Room) -> [RoomScene] {
        scenes.filter { $0.roomID == room.id }
    }

    /// Lights the bridge knows about but that belong to no room — shown separately
    /// rather than silently dropped.
    public var unroomedLights: [Light] {
        let assigned = Set(rooms.flatMap(\.lightIDs))
        return lights.filter { !assigned.contains($0.id) }
    }

    public func isRoomOn(_ room: Room) -> Bool {
        lights(in: room).contains { $0.state.isOn && $0.connection.isCommandable }
    }

    // MARK: - Light commands

    public func setPower(_ on: Bool, for id: Light.ID) {
        applyOptimistically(id, property: .power, { $0.isOn = on }) { [transport] in
            try await transport.setPower(on, for: id)
        }
    }

    public func setBrightness(_ brightness: Double, for id: Light.ID) {
        applyOptimistically(id, property: .brightness, { $0.brightness = brightness }) { [transport] in
            try await transport.setBrightness(brightness, for: id)
        }
    }

    public func setColor(_ color: LightColor, for id: Light.ID) {
        applyOptimistically(id, property: .color, { $0.color = color }) { [transport] in
            try await transport.setColor(color, for: id)
        }
    }

    /// Applies a gradient, and also sets the matching flat colour so a fixture that
    /// ignores gradients (or a bridge that clears them) still lands somewhere sane.
    public func setGradient(_ gradient: LightGradient, for id: Light.ID) {
        if let first = gradient.points.first { setColor(first, for: id) }
        Task { [transport, weak self] in
            do { try await transport.setGradient(gradient, for: id) }
            catch { self?.report("Couldn’t set the gradient", error) }
        }
    }

    public func setEffect(_ effect: String?, for id: Light.ID) {
        Task { [transport, weak self] in
            do { try await transport.setEffect(effect, for: id) }
            catch { self?.report("Couldn’t set the effect", error) }
        }
    }

    public func toggleAll(on: Bool) {
        for room in rooms { setRoomPower(on, room: room) }
        for light in unroomedLights where light.connection.isCommandable {
            setPower(on, for: light.id)
        }
    }

    // MARK: - Room commands

    /// One request for the whole room where the transport supports it, so the room
    /// switches rather than ripples.
    public func setRoomPower(_ on: Bool, room: Room) {
        for id in room.lightIDs {
            guard let i = lights.firstIndex(where: { $0.id == id }) else { continue }
            lights[i].state.isOn = on
        }
        Task { [transport, weak self] in
            do {
                try await transport.setRoomPower(on, room: room)
            } catch {
                self?.report("Couldn’t switch the room", error)
            }
            // Confirm against the bridge either way: a room switch touches several
            // lights and a partial failure is invisible otherwise.
            await self?.resync()
        }
    }

    // MARK: - Scenes

    /// Applies a scene, coalescing rapid presses.
    ///
    /// Hue applies a scene as a transition. Recalling a second scene mid-transition
    /// interrupts the first and leaves lamps at intermediate values, matching neither
    /// scene. Only the last scene in a burst is sent, and a stale resync cannot
    /// overwrite a newer one.
    public func recall(_ scene: RoomScene) {
        pendingRecall?.cancel()
        recallGeneration += 1
        let generation = recallGeneration

        pendingRecall = Task { [transport, weak self] in
            // Let a burst of presses settle before touching the bridge at all.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }

            do {
                try await transport.recallScene(scene.id)
            } catch {
                guard !Task.isCancelled else { return }
                self?.report("Couldn’t apply the scene", error)
            }

            // Wait out the bridge's own transition before believing anything.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.recallGeneration else { return }

            await self.resync()
            // status.active only changes once the room settles, so scenes are
            // re-read after the lights, not before.
            await self.refreshScenes()
        }
    }

    public func refreshScenes() async {
        if let fetched = try? await transport.fetchScenes() { scenes = fetched }
    }

    public func saveScene(named name: String, in room: Room) async {
        do {
            let scene = try await transport.createScene(named: name, in: room.id, actions: [])
            scenes.append(scene)
            scenes.sort { $0.name < $1.name }
        } catch {
            report("Couldn’t save the scene", error)
        }
    }

    public func deleteScene(_ scene: RoomScene) {
        Task { [transport, weak self] in
            do {
                try await transport.deleteScene(scene.id)
                self?.scenes.removeAll { $0.id == scene.id }
            } catch {
                self?.report("Couldn’t delete the scene", error)
            }
        }
    }

    // MARK: - Optimistic writes

    /// Minimum gap between writes to the same light and property.
    ///
    /// Hue rate-limits, and a slider drag produces a value every frame. Cancelling
    /// the previous `Task` does not help: it neither stops a request already in
    /// flight nor prevents the next one starting, so dragging quickly sent dozens of
    /// PUTs a second and the bridge answered 429 with an HTML error page. Ten a
    /// second is the documented ceiling for light commands.
    private static let minimumWriteInterval = Duration.milliseconds(120)

    /// Applies a change locally at once, and sends it at a rate the bridge accepts.
    ///
    /// Only the newest value per light and property is ever sent — intermediate
    /// positions from a drag are worth nothing once the thumb has moved on, so they
    /// are dropped rather than queued.
    private func applyOptimistically(
        _ id: Light.ID,
        property: WriteKey.Property,
        _ localChange: (inout LightState) -> Void,
        _ write: @escaping @Sendable () async throws -> Void
    ) {
        guard let i = lights.firstIndex(where: { $0.id == id }) else { return }
        localChange(&lights[i].state)

        let key = WriteKey(light: id, property: property)
        latestWrite[key] = write

        // One drain loop per key. While it runs, newer values simply replace the
        // pending one.
        guard writeLoop[key] == nil else { return }
        writeLoop[key] = Task { [weak self] in
            while true {
                guard let self else { return }
                guard let next = self.latestWrite.removeValue(forKey: key) else {
                    self.writeLoop[key] = nil
                    return
                }
                do {
                    try await next()
                } catch is CancellationError {
                    self.writeLoop[key] = nil
                    return
                } catch {
                    self.report("The light didn’t accept that change", error)
                    // The bridge has the truth; the optimistic value was a guess.
                    await self.resync()
                }
                try? await Task.sleep(for: Self.minimumWriteInterval)
            }
        }
    }
}
