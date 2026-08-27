import Testing
import Foundation
@testable import LumoBridge
@testable import LumoKit

/// Contract tests against recorded bridge responses.
///
/// Every one of these encodes something that actually broke the app, or would have.
/// The bridge is somebody else's firmware and its payload shape changes without
/// notice; these fail in a second instead of in a living room. They need no
/// hardware, no network and no pairing, so they run anywhere — which is the point.
///
/// The fixtures are modelled on responses observed from a real bridge (API 1.78,
/// BSB002) with identifiers and names replaced by synthetic ones.
@Suite("Bridge response contract")
struct ContractTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                 withExtension: "json"))
        return try Data(contentsOf: url)
    }

    // MARK: - Lights

    @Test("Decodes lights, brightness scale and colour mode")
    func lights() throws {
        let lights = try BridgeCoding.lights(from: fixture("lights")).sorted { $0.name < $1.name }
        #expect(lights.count == 3)

        let desk = try #require(lights.first { $0.name == "Desk lamp" })
        #expect(desk.state.isOn)
        // The bridge reports 0–100; the model is 0–1.
        #expect(abs(desk.state.brightness - 0.72) < 0.001)
        #expect(desk.state.color == .temperature(mireds: 366))

        let off = try #require(lights.first { $0.name == "Off lamp" })
        #expect(off.state.isOn == false)
    }

    @Test("A light with no valid mirek falls back to xy, not to a default temperature")
    func colourModePreference() throws {
        let lights = try BridgeCoding.lights(from: fixture("lights"))
        let play = try #require(lights.first { $0.name == "Play lamp" })
        // mirek is null here; using it anyway would paint the swatch the wrong colour.
        guard case .xy(let x, let y) = play.state.color else {
            Issue.record("expected xy, got \(play.state.color)"); return
        }
        #expect(abs(x - 0.5245) < 0.0001)
        #expect(abs(y - 0.3873) < 0.0001)
    }

    @Test("Capabilities are read from the fixture, not assumed")
    func capabilities() throws {
        let lights = try BridgeCoding.lights(from: fixture("lights"))
        let play = try #require(lights.first { $0.name == "Play lamp" })
        #expect(play.capabilities.supportsGradient)
        #expect(play.capabilities.gradientPoints == 5)
        // "no_effect" is a sentinel, not an effect anyone should see in a list.
        #expect(play.capabilities.effects.contains("candle"))
        #expect(!play.capabilities.effects.contains("no_effect"))

        let off = try #require(lights.first { $0.name == "Off lamp" })
        #expect(!off.capabilities.supportsGradient)
        #expect(off.capabilities.effects.isEmpty)
    }

    // MARK: - Rooms

    @Test("Rooms map through devices to lights")
    func roomsResolveLights() throws {
        // A room lists *devices*; the light ids come from the device list. Getting
        // this wrong yields rooms that are silently empty.
        let rooms = try BridgeCoding.rooms(from: fixture("rooms"), devices: fixture("devices"))
        #expect(rooms.map(\.name) == ["Lounge", "Studio"])   // sorted by name

        let studio = try #require(rooms.first { $0.name == "Studio" })
        #expect(studio.archetype == "office")
        #expect(studio.lightIDs.count == 2)
        #expect(studio.groupedLightID != nil)   // one call switches the whole room
    }

    @Test("A device with no light service contributes no light")
    func devicesWithoutLights() throws {
        let devices = Data("""
        {"data":[{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","type":"device",
          "services":[{"rid":"12121212-1212-4121-8121-121212121212",
                       "rtype":"zigbee_connectivity"}]}]}
        """.utf8)
        let rooms = try BridgeCoding.rooms(from: fixture("rooms"), devices: devices)
        #expect(rooms.allSatisfy { $0.lightIDs.isEmpty })
    }

    // MARK: - Scenes

    @Test("Scene activity and editability come from the bridge")
    func scenes() throws {
        let scenes = try BridgeCoding.scenes(from: fixture("scenes"), appTag: "lumo")

        let evening = try #require(scenes.first { $0.name == "Evening" })
        #expect(evening.isActive)          // status.active == "static"
        #expect(evening.isEditable)        // appdata tags it as ours

        let handmade = try #require(scenes.first { $0.name == "Handmade" })
        #expect(!handmade.isActive)
        // Built in the Hue app: recallable, but not ours to delete.
        #expect(!handmade.isEditable)
    }

    @Test("Zone scenes are skipped, since Lumo shows rooms")
    func zoneScenesIgnored() throws {
        let scenes = try BridgeCoding.scenes(from: fixture("scenes"), appTag: "lumo")
        #expect(!scenes.contains { $0.name == "Zone scene" })
    }

    // MARK: - Events

    @Test("A scene recall event carries colour but no power or brightness")
    func partialEvent() throws {
        // This is the shape that made every light read as off at 50%.
        let deltas = BridgeCoding.deltas(fromEvent: try fixture("event-scene-recall"))
        #expect(deltas.count == 2)

        let first = try #require(deltas.first)
        #expect(first.delta.isOn == nil)         // absent — must stay absent
        #expect(first.delta.brightness == nil)   // absent — must stay absent
        #expect(first.delta.color == .temperature(mireds: 370))
    }

    @Test("Events about things Lumo does not model produce no state change")
    func unmodelledEvent() throws {
        // A signalling update and a grouped_light update: neither should be turned
        // into a light state change.
        let deltas = BridgeCoding.deltas(fromEvent: try fixture("event-unmodelled"))
        #expect(deltas.isEmpty)
    }

    @Test("An effect event reports the effect, and distinguishes cleared from absent")
    func effectEvent() throws {
        let deltas = BridgeCoding.deltas(fromEvent: try fixture("event-effect"))
        #expect(deltas.count == 2)

        // `no_effect` means the bulb is running none — which must be recorded as a
        // change to nil, not as "the event said nothing about effects".
        let started = try #require(deltas.first { $0.delta.effect == .some("candle") })
        #expect(started.delta.isOn == nil)
        let cleared = try #require(deltas.first { $0.id != started.id })
        #expect(cleared.delta.effect == .some(nil))
        #expect(!cleared.delta.isEmpty)
    }

    @Test("A colour-only event says nothing about the effect")
    func colourEventLeavesEffectAlone() throws {
        // The distinction the double optional exists for: absent must not read as
        // "the effect was cleared", or a scene recall would silently stop an effect
        // in the UI while the bulb kept running it.
        let deltas = BridgeCoding.deltas(fromEvent: try fixture("event-scene-recall"))
        #expect(deltas.allSatisfy { $0.delta.effect == nil })
    }

    @Test("Malformed payloads are rejected, not half-decoded")
    func malformed() throws {
        #expect(BridgeCoding.deltas(fromEvent: Data("not json".utf8)).isEmpty)
        #expect(throws: (any Error).self) {
            try BridgeCoding.lights(from: Data("{}".utf8))
        }
    }
}
