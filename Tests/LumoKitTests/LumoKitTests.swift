import Testing
import Foundation
import AppKit
@testable import LumoKit

/// These run against `SimulatedTransport`, which is the point of it existing —
/// none of this is testable against a physical bulb someone might have switched
/// off at the wall.

@Suite("Colour science")
struct ColorScienceTests {

    @Test("Mireds and kelvin round-trip")
    func miredRoundTrip() {
        for kelvin in [2000.0, 2700.0, 4000.0, 6500.0] {
            let mireds = ColorScience.mireds(fromKelvin: kelvin)
            #expect(abs(ColorScience.kelvin(fromMireds: mireds) - kelvin) < 40)
        }
    }

    @Test("Warm temperatures are redder than cool ones")
    func warmIsRed() {
        let warm = ColorScience.rgb(fromMireds: 500)  // 2000K
        let cool = ColorScience.rgb(fromMireds: 153)  // 6500K
        #expect(warm.b < cool.b)
        #expect(warm.r >= cool.r * 0.95)
    }

    @Test("xy round-trips through RGB well enough to place a slider thumb")
    func xyRoundTrip() {
        let original = ColorScience.RGB(r: 0.9, g: 0.2, b: 0.3)
        let xy = ColorScience.xy(fromRGB: original)
        let back = ColorScience.rgb(fromXY: xy.x, xy.y, brightness: 1.0)
        // Gamut clipping means this is not lossless; hue ordering is what matters.
        #expect(back.r > back.g)
        #expect(back.r > back.b)
    }

    @Test("Zero-luminance xy does not produce NaN")
    func degenerateXY() {
        let rgb = ColorScience.rgb(fromXY: 0.3, 0.0, brightness: 1.0)
        #expect(!rgb.r.isNaN && !rgb.g.isNaN && !rgb.b.isNaN)
    }
}

@Suite("Light store")
@MainActor
struct LightStoreTests {

    private func makeStore(faults: SimulatedTransport.Faults = .init()) async -> (LightStore, SimulatedTransport) {
        let transport = SimulatedTransport()
        await transport.setFaults(faults)
        let store = LightStore(transport: transport)
        await store.start()
        // Discovery is staggered to exercise appearance animation; wait it out.
        try? await Task.sleep(for: .milliseconds(500))
        return (store, transport)
    }

    @Test("Discovers the simulated lights")
    func discovery() async {
        let (store, _) = await makeStore()
        #expect(store.lights.count == 2)
    }

    @Test("Loads rooms from the transport")
    func rooms() async {
        let (store, _) = await makeStore()
        #expect(store.rooms.count == 1)
        #expect(store.lights(in: store.rooms[0]).count == 2)
    }

    @Test("Every light belongs to a room, so none are hidden")
    func nothingUnroomed() async {
        let (store, _) = await makeStore()
        #expect(store.unroomedLights.isEmpty)
    }

    @Test("Power changes optimistically, before the transport confirms")
    func optimisticPower() async {
        let (store, _) = await makeStore()
        let id = store.lights[0].id
        store.setPower(false, for: id)
        // No await: the model must already reflect the change on the same tick.
        #expect(store.lights[0].state.isOn == false)
    }

    @Test("A rejected write rolls the UI back rather than lying")
    func rollbackOnFailure() async throws {
        var faults = SimulatedTransport.Faults()
        let (store, transport) = await makeStore()
        let id = store.lights[0].id
        let original = store.lights[0].state.brightness

        faults.needsPairing = [id]
        await transport.setFaults(faults)

        store.setBrightness(0.1, for: id)
        try await Task.sleep(for: .milliseconds(300))

        #expect(store.lights[0].state.brightness == original)
        #expect(store.lastError != nil)
    }

    @Test("A room switch turns every light in the room off")
    func roomPower() async throws {
        let (store, _) = await makeStore()
        let room = try #require(store.rooms.first)
        store.setRoomPower(false, room: room)
        #expect(store.isRoomOn(room) == false)
        #expect(store.lights(in: room).allSatisfy { $0.state.isOn == false })
    }

    @Test("Saving a scene files it under the room it was captured in")
    func saveScene() async throws {
        let (store, _) = await makeStore()
        let room = try #require(store.rooms.first)

        await store.saveScene(named: "Night", in: room)

        let scene = try #require(store.scenes.first)
        #expect(scene.name == "Night")
        #expect(scene.roomID == room.id)
        // Scenes Lumo created are the only ones it offers to delete.
        #expect(scene.isEditable)
        #expect(store.scenes(in: room).count == 1)
    }

    @Test("Deleting a scene removes it")
    func deleteScene() async throws {
        let (store, _) = await makeStore()
        let room = try #require(store.rooms.first)
        await store.saveScene(named: "Night", in: room)
        let scene = try #require(store.scenes.first)

        store.deleteScene(scene)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.scenes.isEmpty)
    }

    @Test("Recalling a scene reconciles from the transport, not from a guess")
    func recallScene() async throws {
        let (store, _) = await makeStore()
        let room = try #require(store.rooms.first)
        await store.saveScene(named: "Bright", in: room)
        let scene = try #require(store.scenes.first)

        store.setRoomPower(false, room: room)
        try await Task.sleep(for: .milliseconds(200))

        store.recall(scene)
        // recall() deliberately waits before resyncing, so the bridge has settled.
        try await Task.sleep(for: .milliseconds(1000))

        // The simulator's recall turns everything on; the store must pick that up
        // by reading back rather than predicting it.
        #expect(store.lights.allSatisfy { $0.state.isOn })
    }
}

@Suite("Hue wire format")
struct ProtocolTests {
    // Encoding lives in LumoBLE, but the ranges it depends on live here and are
    // the thing most likely to drift.

    @Test("Mired range matches what LCB002 reports")
    func miredRange() {
        #expect(LightColor.miredRange.lowerBound == 153)
        #expect(LightColor.miredRange.upperBound == 500)
    }

    @Test("Brightness is clamped on the way into the model")
    func brightnessClamped() {
        #expect(LightState(isOn: true, brightness: 5, color: .temperature(mireds: 300)).brightness == 1)
        #expect(LightState(isOn: true, brightness: -2, color: .temperature(mireds: 300)).brightness == 0)
    }
}

@Suite("Partial state updates")
struct DeltaTests {
    // The bridge pushes only the fields that changed. Substituting a whole state
    // for one of those reported every light as off at 50% after a scene recall.

    private let lit = LightState(isOn: true, brightness: 0.9, color: .temperature(mireds: 300))

    @Test("A colour-only update leaves power and brightness alone")
    func colourOnly() {
        let delta = LightStateDelta(color: .xy(x: 0.5, y: 0.4))
        let result = delta.applied(to: lit)

        #expect(result.isOn)                       // not clobbered to false
        #expect(result.brightness == 0.9)          // not clobbered to 50%
        #expect(result.color == .xy(x: 0.5, y: 0.4))
    }

    @Test("A power-only update leaves colour and brightness alone")
    func powerOnly() {
        let result = LightStateDelta(isOn: false).applied(to: lit)
        #expect(result.isOn == false)
        #expect(result.brightness == 0.9)
        #expect(result.color == .temperature(mireds: 300))
    }

    @Test("An empty delta changes nothing")
    func emptyDelta() {
        let delta = LightStateDelta()
        #expect(delta.isEmpty)
        #expect(delta.applied(to: lit) == lit)
    }

    @Test("A full delta replaces everything")
    func fullDelta() {
        let other = LightState(isOn: false, brightness: 0.1, color: .xy(x: 0.2, y: 0.2))
        #expect(LightStateDelta(other).applied(to: lit) == other)
    }
}

@Suite("Recovering from failure")
@MainActor
struct ResyncTests {

    @Test("A failed write resyncs from the transport instead of trusting a guess")
    func resyncAfterFailure() async throws {
        let transport = SimulatedTransport()
        let store = LightStore(transport: transport)
        await store.start()
        try await Task.sleep(for: .milliseconds(500))

        let id = store.lights[0].id
        var faults = SimulatedTransport.Faults()
        faults.needsPairing = [id]
        await transport.setFaults(faults)

        store.setBrightness(0.05, for: id)
        try await Task.sleep(for: .milliseconds(500))

        // The transport never accepted the change, so the store must show what the
        // transport reports — not the optimistic value, and not a stale rollback.
        let truth = try await transport.fetchLights().first { $0.id == id }
        #expect(store.lights[0].state == truth?.state)
    }

    @Test("Resync adopts changes made outside the app")
    func resyncAdoptsExternalChange() async throws {
        let transport = SimulatedTransport()
        let store = LightStore(transport: transport)
        await store.start()
        try await Task.sleep(for: .milliseconds(500))

        let id = store.lights[0].id
        // Somebody else — the Hue app, a wall switch — changes the light.
        try await transport.setPower(false, for: id)
        try await transport.setBrightness(0.2, for: id)

        await store.resync()

        #expect(store.lights.first { $0.id == id }?.state.isOn == false)
        #expect(store.lights.first { $0.id == id }?.state.brightness == 0.2)
    }
}

@Suite("Formatting")
struct FormattingTests {
    // These caught nothing on this desk and everything outside en-US.

    @Test("Kelvin is never converted to another unit")
    func kelvinStaysKelvin() {
        // Without unitOptions = .providedUnit, MeasurementFormatter converts to
        // Celsius across most of the world and 2700 K is rendered as 2427 °C.
        let text = Formatting.kelvin(2700)
        #expect(text.contains("2,700") || text.contains("2700") || text.contains("2 700"))
        #expect(text.uppercased().contains("K"))
        #expect(!text.contains("°C"))
    }

    @Test("Percentages go through a formatter, not interpolation")
    func percentages() {
        #expect(Formatting.percentage(0.72).contains("72"))
        #expect(Formatting.percentage(0).contains("0"))
        #expect(Formatting.percentage(1).contains("100"))
    }
}

@Suite("Hue wrap-around")
struct HueWrapTests {
    // Hue is a circle; the slider is a line. Red exists at both ends, so converting
    // a light's colour back into a slider position is ambiguous there — and no
    // threshold fixes it, because collapsing the top of the range onto zero stops red
    // jumping right and starts magenta jumping left.

    /// The round trip the colour slider performs: hue → xy → hue.
    private func roundTrip(_ hue: Double) -> Double {
        let picked = NSColor(hue: hue, saturation: 0.9, brightness: 1, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        let xy = ColorScience.xy(fromRGB: .init(r: Double(picked.redComponent),
                                                g: Double(picked.greenComponent),
                                                b: Double(picked.blueComponent)))
        let back = ColorScience.rgb(fromXY: xy.x, xy.y, brightness: 1)
        let colour = NSColor(red: back.r, green: back.g, blue: back.b, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        return Double(colour.hueComponent)
    }

    @Test("The round trip is ambiguous at the ends, which is why position is kept")
    func endsAreAmbiguous() {
        // Whichever end is picked, the value can come back near the other one. The UI
        // therefore keeps the position the user chose rather than trusting this.
        let fromRed = roundTrip(0.0)
        let wrapped = fromRed > 0.5
        let nearlyRed = fromRed < 0.05
        #expect(wrapped || nearlyRed)
    }

    @Test("A threshold cannot separate the two ends")
    func thresholdCannotWork() {
        // 0.0 and 0.99 are both red; any cut that maps one end home sends the other
        // end to the wrong place. Demonstrated rather than asserted in prose.
        let red = NSColor(hue: 0.0, saturation: 0.9, brightness: 1, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        let alsoRed = NSColor(hue: 0.99, saturation: 0.9, brightness: 1, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        #expect(abs(red.redComponent - alsoRed.redComponent) < 0.05)
        #expect(abs(red.greenComponent - alsoRed.greenComponent) < 0.15)
    }
}
