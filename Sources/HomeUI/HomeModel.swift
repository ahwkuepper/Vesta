import Foundation
import Observation
import AppKit
import VestaKit
import VestaBridge
import KasaKit
import KasaUI
import NestCore
import OSLog

enum DeviceKind: String, Codable, CaseIterable { case light = "Light", device = "Device" }
enum DeviceProvider: String { case hue = "Philips Hue", kasa = "Kasa" }
struct HomeDevice: Identifiable {
    let id: String
    let provider: DeviceProvider
    let name: String
    var room: String
    var kind: DeviceKind
    let isPlug: Bool
    let isOn: Bool
    let reachable: Bool
    let status: String
    let brightness: Double?
    let warmth: Double?
    let supportsColor: Bool
    let color: ColorScience.RGB
    let hueLight: Light?
    let kasaDevice: KasaDevice?
}

struct DevicePlacement: Codable, Equatable {
    var room: String?
    var kind: DeviceKind?
    var attention: DeviceAttention?
}

@MainActor @Observable
final class HomeModel {
    let kasa: KasaHome
    var hue: LightStore?
    var hueError: String?
    var hueRefreshing = false
    var placements: [String: DevicePlacement] = [:]
    var savedRooms: [String] = []
    var roomPriorities: [String: RoomPriority] = [:]
    private(set) var roomUse: [String: RoomUse] = [:]
    var smartOrder: Bool { didSet { preferences?.set(smartOrder, forKey: "home.smartOrder") } }
    private var presentedRoomOrder: [String]?
    var search = ""
    var expanded: Set<String> = []
    var collapsed: Set<String> = []
    var schedules: Set<String> = []
    var climateExpanded = false
    var settings = false
    var pairing = false
    var account = false
    var nestReadings: Readings?
    var nestError: String?
    var nestBusy = false
    var nestCommandBusy = false
    var thermostatIndex = 0 { didSet { if oldValue != thermostatIndex { cancelTarget() } } }
    private(set) var targetDraft: ClimateTargetDraft?
    private(set) var nestRetryAt: Date?
    @ObservationIgnored private var targetTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var lastNestReadAttempt: Date?
    var celsius: Bool { didSet { preferences?.set(celsius, forKey: "home.celsius") } }
    var roomDraft = ""
    var localError: String?
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let nest: NestReader
    @ObservationIgnored private var started = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var hueTransport: BridgeTransport?

    init(preferences: UserDefaults? = .standard, kasa: KasaHome = KasaHome(),
         nest: NestReader = NestReader(http: GoogleHTTPClient(allowControl: true), allowsControl: true),
         now: @escaping () -> Date = Date.init) {
        self.preferences = preferences; self.nest = nest; self.kasa = kasa
        self.now = now
        smartOrder = preferences?.object(forKey: "home.smartOrder") as? Bool ?? true
        celsius = preferences?.bool(forKey: "home.celsius") ?? false
        if let data = preferences?.data(forKey: "home.placements.v1"), data.count <= 262144,
           let decoded = try? JSONDecoder().decode([String: DevicePlacement].self, from: data) { placements = decoded }
        savedRooms = Array((preferences?.stringArray(forKey: "home.rooms.v1") ?? []).prefix(100))
        if let data = preferences?.data(forKey: "home.roomPriorities.v1"), data.count <= 65536,
           let values = try? JSONDecoder().decode([String: RoomPriority].self, from: data), values.count <= 100 {
            roomPriorities = values
        }
        if let data = preferences?.data(forKey: "home.roomUse.v1"), data.count <= 262144,
           let values = try? JSONDecoder().decode([String: RoomUse].self, from: data), values.count <= 256 {
            roomUse = values.filter { $0.key.count <= 160 && $0.value.valid(at: now()) }
        }
    }

    static func inferredKind(name: String, isPlug: Bool) -> DeviceKind {
        guard isPlug else { return .light }
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return words.contains(where: { ["lamp", "lamps", "light", "lights", "lighting"].contains($0) }) ? .light : .device
    }
    static func suggestedRoom(name: String, rooms: [String]) -> String {
        func normalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let padded = " " + normalized(name) + " "
        return rooms.sorted { $0.count > $1.count }.first {
            !normalized($0).isEmpty && padded.contains(" " + normalized($0) + " ")
        } ?? "Unassigned"
    }

    var devices: [HomeDevice] {
        var result: [HomeDevice] = (hue?.lights ?? []).map { light in
            let id = "hue:" + light.id.uuidString
            let room = hue?.rooms.first { $0.lightIDs.contains(light.id) }?.name ?? "Unassigned"
            let plug = !light.capabilities.supportsDimming
            let warmth: Double?
            let color: ColorScience.RGB
            switch light.state.color {
            case .temperature(let mireds): warmth = ColorScience.kelvin(fromMireds: mireds); color = ColorScience.rgb(fromMireds: mireds)
            case .xy(let x, let y): warmth = nil; color = ColorScience.rgb(fromXY: x, y)
            }
            return HomeDevice(id: id, provider: .hue, name: light.name,
                room: placements[id]?.room ?? room, kind: placements[id]?.kind ?? Self.inferredKind(name: light.name, isPlug: plug),
                isPlug: plug, isOn: light.state.isOn, reachable: light.connection.isCommandable && hueError == nil && hue?.availability == .ready,
                status: light.connection.shortLabel,
                brightness: light.capabilities.supportsDimming ? light.state.brightness * 100 : nil,
                warmth: light.capabilities.supportsTemperature ? warmth ?? 2700 : nil,
                supportsColor: light.capabilities.supportsColor, color: color, hueLight: light, kasaDevice: nil)
        }
        result += kasa.devices.map { device in
            let id = "kasa:" + device.id
            let warmth = device.supportsTemperature ? Double(device.colorTemperature ?? 2700) : nil
            let color: ColorScience.RGB
            if device.supportsColor, device.colorTemperature == 0 {
                let ns = NSColor(hue: Double(device.hue ?? 0) / 360, saturation: Double(device.saturation ?? 0) / 100, brightness: 1, alpha: 1)
                color = .init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
            } else { color = ColorScience.rgb(fromKelvin: max(2200, warmth ?? 2700)) }
            return HomeDevice(id: id, provider: .kasa, name: device.name,
                room: placements[id]?.room ?? Self.suggestedRoom(name: device.name, rooms: hue?.rooms.map(\.name) ?? []),
                kind: placements[id]?.kind ?? Self.inferredKind(name: device.name, isPlug: !device.isBulb),
                isPlug: !device.isBulb, isOn: device.isOn, reachable: device.canControl,
                status: device.status, brightness: device.brightness.map(Double.init), warmth: warmth,
                supportsColor: device.supportsColor, color: color, hueLight: nil, kasaDevice: device)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var rooms: [String] {
        let names = Set(devices.map(\.room) + savedRooms + (hue?.rooms.map(\.name) ?? []))
        return names.filter { $0 != "Unassigned" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            + (names.contains("Unassigned") ? ["Unassigned"] : [])
    }
    var lightsOn: Int { devices.filter { $0.kind == .light && $0.reachable && $0.isOn }.count }
    private var rankedRooms: [String] {
        smartOrder ? RoomAttention.sorted(rooms: rooms, devices: devices, placements: placements,
                                         priorities: roomPriorities, uses: roomUse, at: now()) : rooms
    }
    var orderedRooms: [String] {
        guard let presentedRoomOrder else { return rankedRooms }
        let current = Set(rooms)
        return presentedRoomOrder.filter { current.contains($0) } + rankedRooms.filter { !presentedRoomOrder.contains($0) }
    }
    func beginPresentation() { presentedRoomOrder = rankedRooms }
    func endPresentation() { presentedRoomOrder = nil }
    func reconcilePresentedRooms() {
        if presentedRoomOrder != nil { presentedRoomOrder = orderedRooms }
    }
    func recordRoomUse(_ room: String) {
        guard smartOrder, room.count <= 160, !room.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        reconcilePresentedRooms()
        let date = now()
        // Do not encode/write preferences for every slider frame.
        if let previous = roomUse[room], (0..<5).contains(date.timeIntervalSince(previous.lastUsed)) { return }
        var value = roomUse[room] ?? RoomUse(lastUsed: date, lastCounted: date, frequency: 1)
        value.record(at: date); roomUse[room] = value
        if roomUse.count > 256 {
            roomUse = Dictionary(uniqueKeysWithValues: roomUse.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(256).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(roomUse) { preferences?.set(data, forKey: "home.roomUse.v1") }
    }
    func resetLearnedOrder() {
        reconcilePresentedRooms(); roomUse = [:]; preferences?.removeObject(forKey: "home.roomUse.v1")
    }
    func setPriority(_ priority: RoomPriority, room: String) {
        guard roomPriorities[room] != nil || roomPriorities.count < 100 else { return }
        roomPriorities[room] = priority == .automatic ? nil : priority
        savePriorities()
    }
    func setAttention(_ attention: DeviceAttention, device: HomeDevice) {
        var value = placements[device.id] ?? DevicePlacement()
        value.attention = attention == .automatic ? nil : attention
        placements[device.id] = value; savePlacements()
    }
    private func savePriorities() {
        if let data = try? JSONEncoder().encode(roomPriorities) { preferences?.set(data, forKey: "home.roomPriorities.v1") }
    }
    func visible(in room: String) -> [HomeDevice] {
        devices.filter { $0.room == room && (search.isEmpty || $0.name.localizedStandardContains(search) || room.localizedStandardContains(search)) }
    }
    func assign(_ device: HomeDevice, room: String? = nil, kind: DeviceKind? = nil) {
        var value = placements[device.id] ?? DevicePlacement()
        if let room { value.room = room }
        if let kind { value.kind = kind }
        placements[device.id] = value
        savePlacements()
    }
    func addRoom() {
        let name = roomDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !name.contains(where: { $0.isNewline }), savedRooms.count < 100 else { return }
        if !rooms.contains(name) { savedRooms.append(name) }
        preferences?.set(savedRooms, forKey: "home.rooms.v1"); roomDraft = ""
    }
    private func savePlacements() {
        do { preferences?.set(try JSONEncoder().encode(placements), forKey: "home.placements.v1") }
        catch { localError = "Room assignments couldn’t be saved. Try again." }
    }
    func exportLayout() throws -> Data {
        // Include Automatic for known rooms so transferring a reset also clears
        // a Keep low choice on the receiving Mac. Usage history is never exported.
        let choices = Dictionary(uniqueKeysWithValues: rooms.filter { $0 != "Unassigned" }.map {
            ($0, roomPriorities[$0] ?? .automatic)
        }).merging(roomPriorities) { _, explicit in explicit }
        return try HomeLayoutFile(rooms: rooms.filter { $0 != "Unassigned" }, placements: placements, celsius: celsius,
                                  roomPriorities: choices, smartOrder: smartOrder).encoded()
    }
    func importLayout(_ data: Data) throws {
        let incoming = try HomeLayoutFile.decode(data)
        let mergedRooms = Array(Set(savedRooms + incoming.rooms)).sorted()
        let mergedPlacements = placements.merging(incoming.placements) { _, imported in imported }
        let priorities = roomPriorities.merging(incoming.roomPriorities ?? [:]) { _, imported in imported }
        let merged = try HomeLayoutFile(rooms: mergedRooms, placements: mergedPlacements, celsius: incoming.celsius,
                                        roomPriorities: priorities, smartOrder: incoming.smartOrder ?? smartOrder).validated()
        _ = try merged.encoded() // Validate the complete merge before changing anything.
        placements = merged.placements; savedRooms = merged.rooms; celsius = merged.celsius
        roomPriorities = priorities; smartOrder = merged.smartOrder ?? smartOrder; savePriorities()
        savePlacements(); preferences?.set(savedRooms, forKey: "home.rooms.v1")
    }
    func power(_ device: HomeDevice, _ on: Bool, recordUse: Bool = true) {
        guard device.reachable else { return }
        if recordUse { recordRoomUse(device.room) }
        if let light = device.hueLight { hue?.setPower(on, for: light.id) }
        if let kasaDevice = device.kasaDevice { kasa.power(on, device: kasaDevice) }
    }
    func allLights(_ on: Bool, room: String? = nil) {
        let targets = devices.filter { $0.kind == .light && $0.reachable && (room == nil || $0.room == room) }
        if let room, !targets.isEmpty { recordRoomUse(room) }
        for device in targets { power(device, on, recordUse: false) }
    }
    func brightness(_ device: HomeDevice, _ value: Double) {
        guard device.reachable, device.isOn, device.brightness != nil, value.isFinite else { return }
        recordRoomUse(device.room)
        let bounded = min(100, max(1, value))
        if let light = device.hueLight { hue?.setBrightness(bounded / 100, for: light.id) }
        if let kasaDevice = device.kasaDevice { kasa.control(.brightness(Int(bounded)), device: kasaDevice) }
    }
    func warmth(_ device: HomeDevice, _ value: Double) {
        guard device.reachable, device.isOn, device.warmth != nil, value.isFinite else { return }
        recordRoomUse(device.room)
        let bounded = min(6500, max(2500, value))
        if let light = device.hueLight { hue?.setColor(.temperature(mireds: ColorScience.mireds(fromKelvin: bounded)), for: light.id) }
        if let kasaDevice = device.kasaDevice { kasa.control(.temperature(Int(bounded)), device: kasaDevice) }
    }
    func color(_ device: HomeDevice, _ color: NSColor) {
        guard device.reachable, device.isOn, device.supportsColor, let rgb = color.usingColorSpace(.deviceRGB) else { return }
        recordRoomUse(device.room)
        if let light = device.hueLight {
            let xy = ColorScience.xy(fromRGB: .init(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent))
            hue?.setColor(.xy(x: xy.x, y: xy.y), for: light.id)
        }
        if let kasaDevice = device.kasaDevice { kasa.control(.color(hue: Int(rgb.hueComponent * 360), saturation: Int(rgb.saturationComponent * 100)), device: kasaDevice) }
    }

    func start() async {
        guard !started else { return }; started = true
        async let kasaStart: Void = kasa.start()
        async let hueStart: Void = connectHue()
        async let nestStart: Void = refreshNest()
        _ = await (kasaStart, hueStart, nestStart)
        Logger(subsystem: "io.github.ahwkuepper.VestaHome", category: "connections").notice(
            "Initial read: Hue \(self.hue?.lights.count ?? 0, privacy: .public), Kasa \(self.kasa.devices.count, privacy: .public) (ready \(self.kasa.devices.filter(\.canControl).count, privacy: .public)), Nest \(self.nestReadings?.thermostats.count ?? 0, privacy: .public).")
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.refreshHue()
                if self.nestError == nil { await self.refreshNest() }
            }
        }
    }
    func refresh() async {
        async let a: Void = kasa.refresh()
        async let b: Void = connectHue()
        async let c: Void = refreshNest()
        _ = await (a, b, c)
    }
    func opened() async {
        guard started else { return }
        await refresh()
    }
    func connectHue() async {
        guard !hueRefreshing else { return }
        if hue != nil { await refreshHue(); return }
        hueRefreshing = true; defer { hueRefreshing = false }
        let state = await Task.detached { BridgeStore.read() }.value
        switch state {
        case .paired(let credentials):
            let transport = BridgeTransport(credentials: credentials)
            let store = LightStore(transport: transport)
            hueTransport = transport; hue = store; hueError = nil
            await store.start()
            if store.lights.isEmpty { hueError = "Hue hasn’t returned any lights. Check home Wi-Fi and Local Network access." }
        case .notPaired: hueError = "Connect your Hue Bridge in Connections."
        case .unreadable: hueError = "Allow Vesta Home to access the saved Hue pairing in Keychain, then refresh."
        }
    }
    func refreshHue() async {
        guard !hueRefreshing, let hue, let hueTransport else { return }
        hueRefreshing = true; defer { hueRefreshing = false }
        do {
            _ = try await hueTransport.fetchLights()
            await hue.resync(); await hue.refreshRoomsAndScenes(); hueError = nil
        } catch { hueError = "Hue is unavailable. Check home Wi-Fi, then refresh. " + error.localizedDescription }
    }
    func reconnectedHue() async {
        await hue?.stop(); hue = nil; hueTransport = nil; await connectHue()
    }

    var thermostat: Readings.Thermostat? {
        guard let list = nestReadings?.thermostats, !list.isEmpty else { return nil }
        return list[max(0, min(thermostatIndex, list.count - 1))]
    }
    var climateWritable: Bool {
        thermostat?.connectivity == "ONLINE" && nestError == nil && !nestBusy && !nestCommandBusy
            && thermostat?.resource != nil && nestRetryAt == nil
    }
    func temperatureLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: celsius ? "%.1f°" : "%.0f°", celsius ? value : value * 9 / 5 + 32)
    }
    func refreshNest(force: Bool = false) async {
        guard !nestBusy, !nestCommandBusy, targetDraft == nil, nestRetryAt == nil else { return }
        // Repeated Refresh clicks must not consume the entire shared Google quota.
        if let attempt = lastNestReadAttempt, (0..<15).contains(now().timeIntervalSince(attempt)) { return }
        if !force, nestError == nil, let date = nestReadings?.fetchedAt,
           (0..<60).contains(now().timeIntervalSince(date)) { return }
        lastNestReadAttempt = now()
        nestBusy = true; defer { nestBusy = false }
        do { nestReadings = try await nest.read(); nestError = nil }
        catch { await handleNestError(error, changing: false) }
    }
    private func handleNestError(_ error: Error, changing: Bool) async {
        nestError = (changing ? "The thermostat change wasn’t confirmed. " : "") + error.localizedDescription
        guard error as? ReaderError == .rateLimited else { return }
        let deadline = await nest.retryNotBefore ?? now().addingTimeInterval(60)
        nestRetryAt = deadline
        nestError = "Google is temporarily limiting requests. Readings will refresh after "
            + deadline.formatted(date: .omitted, time: .shortened)
            + (changing ? ". Your change wasn’t confirmed; it won’t be resent automatically." : ".")
        recoveryTask?.cancel()
        let delay = max(1, deadline.timeIntervalSince(now()))
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.nestRetryAt = nil
            await self.refreshNest(force: true)
        }
    }
    func nestCommand(_ command: NestCommand) {
        guard climateWritable else { return }
        cancelTarget()
        performNestCommand(command)
    }
    private func performNestCommand(_ command: NestCommand) {
        guard climateWritable, let resource = thermostat?.resource else { cancelTarget(); return }
        nestCommandBusy = true
        Task {
            defer { nestCommandBusy = false; targetDraft = nil }
            do { nestReadings = try await nest.execute(command, resource: resource); nestError = nil }
            catch {
                // A failed/ambiguous write is never replayed or followed by another quota-consuming read.
                await handleNestError(error, changing: true)
            }
        }
    }
    func cancelTarget() {
        targetTask?.cancel(); targetTask = nil; targetDraft = nil
    }
    func targetTemperature(cooling: Bool) -> Double? {
        if let targetDraft, targetDraft.resource == thermostat?.resource {
            return cooling ? targetDraft.cool : targetDraft.heat
        }
        return cooling ? thermostat?.coolCelsius : thermostat?.heatCelsius
    }
    func stepTarget(_ delta: Double, cooling: Bool = false) {
        guard climateWritable, delta.isFinite, let t = thermostat, t.eco == "OFF",
              let resource = t.resource, let mode = t.mode else { return }
        var draft = targetDraft ?? ClimateTargetDraft(resource: resource, mode: mode,
                                                      heat: t.heatCelsius, cool: t.coolCelsius)
        guard draft.resource == resource, draft.mode == mode else { cancelTarget(); return }
        let step = delta * (celsius ? 0.5 : 5.0 / 9.0)
        if mode == "HEAT", let heat = draft.heat { draft.heat = min(32, max(10, heat + step)) }
        else if mode == "COOL", let cool = draft.cool { draft.cool = min(32, max(10, cool + step)) }
        else if mode == "HEATCOOL", let heat = draft.heat, let cool = draft.cool {
            if cooling { draft.cool = min(32, max(heat + 0.5, cool + step)) }
            else { draft.heat = max(10, min(cool - 0.5, heat + step)) }
        } else { return }
        cancelTarget()
        // Returning to the confirmed target cancels the whole burst, including rounding noise.
        guard !draft.matches(t) else { return }
        targetDraft = draft
        targetTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.commitTarget()
        }
    }
    func commitTarget() {
        targetTask?.cancel(); targetTask = nil
        guard let draft = targetDraft, let t = thermostat, t.resource == draft.resource,
              t.mode == draft.mode, t.eco == "OFF", let command = draft.command else { cancelTarget(); return }
        performNestCommand(command)
    }
}

struct ClimateTargetDraft {
    let resource: String
    let mode: String
    var heat: Double?
    var cool: Double?
    var command: NestCommand? {
        if mode == "HEAT", let heat { return .heat(heat) }
        if mode == "COOL", let cool { return .cool(cool) }
        if mode == "HEATCOOL", let heat, let cool { return .range(heat: heat, cool: cool) }
        return nil
    }
    func matches(_ t: Readings.Thermostat) -> Bool {
        func equal(_ a: Double?, _ b: Double?) -> Bool {
            if a == nil && b == nil { return true }
            guard let a, let b else { return false }
            return abs(a - b) < 0.000001
        }
        return equal(heat, t.heatCelsius) && equal(cool, t.coolCelsius)
    }
}
