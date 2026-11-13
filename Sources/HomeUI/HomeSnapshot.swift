import SwiftUI
import AppKit
import VestaDesign
import VestaKit
import KasaUI
import NestCore

public enum HomeSnapshot {
    @MainActor public static func render(to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        GlassSettings.isEnabled = false
        let model = HomeModel(preferences: nil, kasa: KasaHome(demo: true))
        let lamp = Light(id: UUID(), name: "Sofa lamp", state: .init(isOn: true, brightness: 0.72, color: .temperature(mireds: 370)), connection: .ready)
        let room = Room(id: UUID(), name: "Living room", lightIDs: [lamp.id])
        let scenes = ["Evening", "Reading", "Candlelight", "Tropical twilight"].map {
            RoomScene(id: UUID(), name: $0, roomID: room.id)
        }
        model.hue = LightStore(transport: SimulatedTransport(), initialLights: [lamp], initialRooms: [room], initialScenes: scenes)
        for device in model.devices where device.provider == .kasa {
            let room = device.name == "Charger" ? "Garage" : device.name == "Reading lamp" ? "Office"
                : device.name.contains("Porch") ? "Porch" : "Living room"
            model.assign(device, room: room)
            if device.name == "String lights" { model.setAttention(.background, device: device) }
        }
        model.recordRoomUse("Office")
        let data = Data(#"{"devices":[{"type":"sdm.devices.types.THERMOSTAT","parentRelations":[{"displayName":"Hallway"}],"traits":{"sdm.devices.traits.Temperature":{"ambientTemperatureCelsius":21.5},"sdm.devices.traits.Humidity":{"ambientHumidityPercent":56},"sdm.devices.traits.Connectivity":{"status":"ONLINE"},"sdm.devices.traits.ThermostatMode":{"mode":"HEAT","availableModes":["HEAT","OFF"]},"sdm.devices.traits.ThermostatHvac":{"status":"OFF"},"sdm.devices.traits.ThermostatEco":{"mode":"OFF"},"sdm.devices.traits.ThermostatTemperatureSetpoint":{"heatCelsius":20}}}]}"#.utf8)
        model.nestReadings = try Readings.decode(data, fetchedAt: Date())
        for dark in [false, true] {
            for state in ["rooms", "collapsed", "expanded", "connections"] {
                model.settings = state == "connections"; model.climateExpanded = state == "expanded"
                model.collapsed = state == "collapsed" ? Set(model.rooms.filter { $0 != "Living room" }) : []
                model.search = state == "expanded" ? "Sofa" : ""
                model.expanded = state == "expanded" ? ["hue:" + lamp.id.uuidString] : []
                let size = CGSize(width: 330, height: 750)
                let hosting = NSHostingView(rootView: HomeView(model: model, maximumHeight: size.height)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: NSColor(white: dark ? 0.12 : 0.97, alpha: 1))))
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = hosting
                for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)); hosting.frame.size = size; hosting.layoutSubtreeIfNeeded() }
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: directory.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
