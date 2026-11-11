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
}

@MainActor @Observable
final class HomeModel {
    let kasa: KasaHome
    var hue: LightStore?
    var hueError: String?
    var hueRefreshing = false
    var placements: [String: DevicePlacement] = [:]
    var savedRooms: [String] = []
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
    var thermostatIndex = 0
    var celsius: Bool { didSet { preferences?.set(celsius, forKey: "home.celsius") } }
    var roomDraft = ""
    var localError: String?
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored let nest: NestReader
    @ObservationIgnored private var started = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var hueTransport: BridgeTransport?

    init(preferences: UserDefaults? = .standard, kasa: KasaHome = KasaHome(),
         nest: NestReader = NestReader(http: GoogleHTTPClient(allowControl: true), allowsControl: true)) {
        self.preferences = preferences; self.nest = nest; self.kasa = kasa
        celsius = preferences?.bool(forKey: "home.celsius") ?? false
        if let data = preferences?.data(forKey: "home.placements.v1"), data.count <= 262144,
           let decoded = try? JSONDecoder().decode([String: DevicePlacement].self, from: data) { placements = decoded }
        savedRooms = Array((preferences?.stringArray(forKey: "home.rooms.v1") ?? []).prefix(100))
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
        try HomeLayoutFile(rooms: rooms.filter { $0 != "Unassigned" }, placements: placements, celsius: celsius).encoded()
    }
    func importLayout(_ data: Data) throws {
        let incoming = try HomeLayoutFile.decode(data)
        let mergedRooms = Array(Set(savedRooms + incoming.rooms)).sorted()
        let mergedPlacements = placements.merging(incoming.placements) { _, imported in imported }
        let merged = try HomeLayoutFile(rooms: mergedRooms, placements: mergedPlacements, celsius: incoming.celsius).validated()
        _ = try merged.encoded() // Validate the complete merge before changing anything.
        placements = merged.placements; savedRooms = merged.rooms; celsius = merged.celsius
        savePlacements(); preferences?.set(savedRooms, forKey: "home.rooms.v1")
    }
    func power(_ device: HomeDevice, _ on: Bool) {
        guard device.reachable else { return }
        if let light = device.hueLight { hue?.setPower(on, for: light.id) }
        if let kasaDevice = device.kasaDevice { kasa.power(on, device: kasaDevice) }
    }
    func allLights(_ on: Bool, room: String? = nil) {
        for device in devices where device.kind == .light && (room == nil || device.room == room) { power(device, on) }
    }
    func brightness(_ device: HomeDevice, _ value: Double) {
        guard device.reachable, device.isOn, device.brightness != nil, value.isFinite else { return }
        let bounded = min(100, max(1, value))
        if let light = device.hueLight { hue?.setBrightness(bounded / 100, for: light.id) }
        if let kasaDevice = device.kasaDevice { kasa.control(.brightness(Int(bounded)), device: kasaDevice) }
    }
    func warmth(_ device: HomeDevice, _ value: Double) {
        guard device.reachable, device.isOn, device.warmth != nil, value.isFinite else { return }
        let bounded = min(6500, max(2500, value))
        if let light = device.hueLight { hue?.setColor(.temperature(mireds: ColorScience.mireds(fromKelvin: bounded)), for: light.id) }
        if let kasaDevice = device.kasaDevice { kasa.control(.temperature(Int(bounded)), device: kasaDevice) }
    }
    func color(_ device: HomeDevice, _ color: NSColor) {
        guard device.reachable, device.isOn, device.supportsColor, let rgb = color.usingColorSpace(.deviceRGB) else { return }
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
        return list[min(thermostatIndex, list.count - 1)]
    }
    var climateWritable: Bool {
        thermostat?.connectivity == "ONLINE" && nestError == nil && !nestBusy && !nestCommandBusy
            && thermostat?.resource != nil
    }
    func temperatureLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: celsius ? "%.1f°" : "%.0f°", celsius ? value : value * 9 / 5 + 32)
    }
    func refreshNest() async {
        guard !nestBusy, !nestCommandBusy else { return }
        nestBusy = true; defer { nestBusy = false }
        do { nestReadings = try await nest.read(); nestError = nil }
        catch { nestError = error.localizedDescription }
    }
    func nestCommand(_ command: NestCommand) {
        guard climateWritable, let resource = thermostat?.resource else { return }
        nestCommandBusy = true
        Task {
            defer { nestCommandBusy = false }
            do { nestReadings = try await nest.execute(command, resource: resource); nestError = nil }
            catch {
                nestError = "The thermostat change wasn’t confirmed. " + error.localizedDescription
                // Read back once. Never replay a potentially successful mutation.
                if let readback = try? await nest.read() { nestReadings = readback }
            }
        }
    }
    func stepTarget(_ delta: Double, cooling: Bool = false) {
        guard let t = thermostat, t.eco == "OFF" else { return }
        let step = celsius ? 0.5 : 5.0 / 9.0
        if t.mode == "HEAT", let heat = t.heatCelsius { nestCommand(.heat(min(32, max(10, heat + delta * step)))) }
        if t.mode == "COOL", let cool = t.coolCelsius { nestCommand(.cool(min(32, max(10, cool + delta * step)))) }
        if t.mode == "HEATCOOL", let heat = t.heatCelsius, let cool = t.coolCelsius {
            nestCommand(.range(heat: cooling ? heat : min(cool - 0.5, max(10, heat + delta * step)),
                               cool: cooling ? max(heat + 0.5, min(32, cool + delta * step)) : cool))
        }
    }
}
