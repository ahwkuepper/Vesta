import Foundation
import Observation

public enum HomeLayout: String, CaseIterable, Identifiable {
    case favorites, rooms, tabs
    public var id: String { rawValue }
    public var title: String {
        switch self { case .favorites: "Quick access"; case .rooms: "By room"; case .tabs: "Tabs" }
    }
    public var subtitle: String {
        switch self {
        case .favorites: "Your favorites, then every light."
        case .rooms: "Everything where it belongs."
        case .tabs: "Lights and devices, one tap apart."
        }
    }
}

enum HomeCategory: String, CaseIterable { case lights = "Light", devices = "Device" }
enum HomeSource: String { case hue = "Philips Hue", kasa = "Kasa" }

struct HomeDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var room: String
    let source: HomeSource
    let isPlug: Bool
    var category: HomeCategory = .lights
    var isOn: Bool = true
    var brightness: Double? = nil
    var supportsTemperature = false
    var supportsColor = false
    var warmth: Double = 2700
    var hue: Double = 35
    var colorMode = false
    var favorite = false
    var reachable = true
}

@MainActor @Observable
public final class HomeModel {
    var devices = HomeModel.sampleDevices
    var target = 68.0
    var temperature = 70.5
    var humidity = 56
    var heatEnabled = true
    var eco = false
    var celsius = false
    var selectedLayout: HomeLayout = .rooms
    var climateExpanded = false
    var expandedDevices: Set<String> = []
    var search = ""
    var selectedTab: HomeCategory = .lights
    var selectedRoom = "All rooms"
    var collapsedRooms: Set<String> = []
    var activeScene: String?

    public init() {}
    var rooms: [String] { devices.map(\.room).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var lights: [HomeDevice] { devices.filter { $0.category == .lights } }
    var otherDevices: [HomeDevice] { devices.filter { $0.category == .devices } }
    var lightsOn: Int { lights.filter { $0.isOn && $0.reachable }.count }
    var heating: Bool { heatEnabled && !eco && target > temperature }
    var climateStatus: String { !heatEnabled ? "Off" : eco ? "Eco" : heating ? "Heating" : "Idle" }
    var targetLabel: String { valueLabel(target) }
    func valueLabel(_ fahrenheit: Double) -> String {
        let number = celsius ? (fahrenheit - 32) * 5 / 9 : fahrenheit
        return String(format: "%.0f°", number)
    }
    func matches(_ d: HomeDevice) -> Bool {
        search.isEmpty || d.name.localizedCaseInsensitiveContains(search) || d.room.localizedCaseInsensitiveContains(search)
    }
    func filtered(_ list: [HomeDevice]) -> [HomeDevice] { list.filter(matches) }
    func change(_ id: String, _ edit: (inout HomeDevice) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        edit(&devices[i]); activeScene = nil
    }
    func power(_ id: String, _ on: Bool) {
        guard devices.first(where: { $0.id == id })?.reachable == true else { return }
        change(id) { $0.isOn = on }
    }
    func toggleAll(_ on: Bool, room: String? = nil) {
        for i in devices.indices where devices[i].category == .lights && devices[i].reachable
            && (room == nil || devices[i].room == room) { devices[i].isOn = on }
        activeScene = nil
    }
    func stepTarget(_ delta: Double) {
        target = min(85, max(50, target + delta * (celsius ? 1.8 : 1)))
    }
    func setBrightness(_ id: String, _ value: Double) {
        guard let device = devices.first(where: { $0.id == id }), device.brightness != nil,
              device.reachable, device.isOn else { return }
        change(id) { $0.brightness = min(100, max(1, value)) }
    }
    func scene(_ name: String) {
        for i in devices.indices where devices[i].category == .lights && devices[i].reachable {
            devices[i].isOn = name != "All off"
            if devices[i].brightness != nil && name != "All off" {
                devices[i].brightness = name == "Evening" ? 35 : 100
                if devices[i].supportsTemperature { devices[i].warmth = name == "Evening" ? 2400 : 4000 }
                devices[i].colorMode = false
            }
        }
        activeScene = name
    }
    func reset() {
        devices = Self.sampleDevices; target = 68; temperature = 70.5; humidity = 56
        heatEnabled = true; eco = false; celsius = false; climateExpanded = false
        expandedDevices = []; search = ""; selectedTab = .lights; selectedRoom = "All rooms"
        collapsedRooms = []; activeScene = nil
    }
    static var sampleDevices: [HomeDevice] { [
        .init(id: "sofa", name: "Sofa lamp", room: "Living room", source: .hue, isPlug: false,
              brightness: 72, supportsTemperature: true, supportsColor: true, favorite: true),
        .init(id: "reading", name: "Reading lamp", room: "Living room", source: .kasa, isPlug: true,
              favorite: true),
        .init(id: "shelf", name: "Bookshelf", room: "Living room", source: .hue, isPlug: false,
              brightness: 45, supportsTemperature: true, supportsColor: true),
        .init(id: "porch-left", name: "Porch left", room: "Porch", source: .kasa, isPlug: false,
              brightness: 69, favorite: true),
        .init(id: "porch-right", name: "Porch right", room: "Porch", source: .kasa, isPlug: false,
              brightness: 69),
        .init(id: "bedside", name: "Bedside lamp", room: "Bedroom", source: .kasa, isPlug: true,
              isOn: false),
        .init(id: "ceiling", name: "Ceiling", room: "Bedroom", source: .hue, isPlug: false,
              isOn: false, brightness: 80, supportsTemperature: true),
        .init(id: "guest", name: "Guest lamp", room: "Guest room", source: .kasa, isPlug: true,
              isOn: false, reachable: false),
        .init(id: "charger", name: "Car charger", room: "Garage", source: .kasa, isPlug: true,
              category: .devices),
        .init(id: "fan", name: "Fan", room: "Bedroom", source: .kasa, isPlug: true,
              category: .devices, isOn: false)
    ] }
}
