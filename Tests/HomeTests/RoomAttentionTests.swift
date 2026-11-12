import Testing
import Foundation
import KasaUI
import VestaKit
@testable import HomeUI

@Suite("Adaptive room ordering", .serialized) @MainActor
struct RoomAttentionTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func device(_ name: String, room: String, on: Bool = true, kind: DeviceKind = .light,
                        reachable: Bool = true) -> HomeDevice {
        HomeDevice(id: "kasa:" + name, provider: .kasa, name: name, room: room, kind: kind,
                   isPlug: true, isOn: on, reachable: reachable, status: "Ready", brightness: nil,
                   warmth: nil, supportsColor: false, color: .init(r: 1, g: 1, b: 1), hueLight: nil, kasaDevice: nil)
    }
    private func use(_ time: Date, frequency: Double = 1) -> RoomUse {
        .init(lastUsed: time, lastCounted: time, frequency: frequency)
    }

    @Test func activeLightsThenRecentUseWithoutScheduledDecorationsDominating() {
        let rooms = ["Garage", "Office", "Bedroom", "Porch", "Attic", "Unassigned"]
        let devices = [device("Lamp", room: "Bedroom"), device("Christmas lights", room: "Porch"),
                       device("Car charger", room: "Garage", kind: .device), device("Garage light", room: "Garage")]
        let order = RoomAttention.sorted(rooms: rooms, devices: devices, placements: [:], priorities: [:],
                                         uses: ["Office": use(date)], at: date)
        #expect(order == ["Bedroom", "Office", "Attic", "Porch", "Garage", "Unassigned"])
    }
    @Test func backgroundDoesNotHideEverydayLightsInTheSameRoom() {
        let devices = [device("Halloween decorations", room: "Porch"), device("Reading lamp", room: "Porch")]
        #expect(RoomAttention.sorted(rooms: ["Office", "Porch"], devices: devices, placements: [:],
                                     priorities: [:], uses: ["Office": use(date)], at: date).first == "Porch")
        #expect(RoomAttention.sorted(rooms: ["Office", "Porch"], devices: [device("Lamp", room: "Porch", reachable: false)],
                                     placements: [:], priorities: [:], uses: ["Office": use(date)], at: date).first == "Office")
    }
    @Test func explicitChoicesOverrideGuessesAndLearning() {
        let decoration = device("Christmas lights", room: "Porch")
        let placement = DevicePlacement(attention: .everyday)
        #expect(RoomAttention.sorted(rooms: ["Office", "Porch"], devices: [decoration], placements: [decoration.id: placement],
                                     priorities: [:], uses: ["Office": use(date)], at: date).first == "Porch")
        #expect(RoomAttention.sorted(rooms: ["Office", "Porch"], devices: [decoration], placements: [decoration.id: placement],
                                     priorities: ["Porch": .low], uses: ["Porch": use(date, frequency: 100)], at: date).first == "Office")
    }
    @Test func repeatedManualUseCanOvercomeAUtilityRoomPriorAndFades() {
        let devices = [device("Garage lamp", room: "Garage")]
        let history = ["Garage": use(date, frequency: 5)]
        #expect(RoomAttention.sorted(rooms: ["Office", "Garage"], devices: devices, placements: [:],
                                     priorities: [:], uses: history, at: date).first == "Garage")
        let muchLater = date.addingTimeInterval(90 * 86400)
        #expect(RoomAttention.sorted(rooms: ["Office", "Garage"], devices: devices, placements: [:],
                                     priorities: [:], uses: history, at: muchLater).first == "Office")
        #expect(RoomAttention.sorted(rooms: ["Office", "Garage"], devices: devices, placements: [:],
                                     priorities: ["Garage": .normal], uses: history, at: muchLater).first == "Garage")
    }
    @Test func orderStaysStillUntilNextPresentationIncludingNewRooms() {
        var clock = date
        let model = HomeModel(preferences: nil, now: { clock })
        model.savedRooms = ["Alpha", "Beta", "Garage"]
        model.recordRoomUse("Beta")
        model.beginPresentation()
        #expect(model.orderedRooms == ["Beta", "Alpha", "Garage"])
        clock = clock.addingTimeInterval(60); model.recordRoomUse("Alpha")
        model.savedRooms.append("Delta"); model.reconcilePresentedRooms()
        #expect(model.orderedRooms == ["Beta", "Alpha", "Garage", "Delta"])
        model.endPresentation(); model.beginPresentation()
        #expect(model.orderedRooms == ["Alpha", "Beta", "Delta", "Garage"])
        model.smartOrder = false
        model.endPresentation(); model.beginPresentation()
        #expect(model.orderedRooms == model.rooms)
    }
    @Test func manualUsePersistsWithoutSliderFramesInflatingFrequency() throws {
        let name = "RoomAttentionTests." + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name)); defer { prefs.removePersistentDomain(forName: name) }
        var clock = date
        let model = HomeModel(preferences: prefs, now: { clock })
        for _ in 0..<100 { model.recordRoomUse("Office") }
        #expect(model.roomUse["Office"]?.frequency == 1)
        clock = clock.addingTimeInterval(61); model.recordRoomUse("Office")
        let restored = HomeModel(preferences: prefs, now: { clock })
        #expect(restored.roomUse == model.roomUse)
        #expect((restored.roomUse["Office"]?.frequency ?? 0) > 1.9)
        restored.setPriority(.low, room: "Garage"); restored.resetLearnedOrder()
        let reset = HomeModel(preferences: prefs, now: { clock })
        #expect(reset.roomUse.isEmpty); #expect(reset.roomPriorities["Garage"] == .low)
    }
    @Test func automationReadsAndGlobalActionsNeverBecomeManualRoomInterest() async throws {
        let model = HomeModel(preferences: nil, kasa: KasaHome(demo: true), now: { date })
        let lamp = try #require(model.devices.first { $0.name == "Bedroom lamp" })
        model.assign(lamp, room: "Bedroom")
        _ = model.orderedRooms; _ = model.devices
        await model.opened() // A non-started test model must not connect to hardware.
        model.allLights(false)
        #expect(model.roomUse.isEmpty)
        model.allLights(true, room: "Bedroom")
        #expect(Set(model.roomUse.keys) == ["Bedroom"])
        model.resetLearnedOrder(); model.smartOrder = false
        model.allLights(false, room: "Bedroom")
        #expect(model.roomUse.isEmpty)
    }
    @Test func layoutTransfersChoicesButNeverUseHistoryAndAcceptsOldLayouts() throws {
        let source = HomeModel(preferences: nil, kasa: KasaHome(demo: true), now: { date })
        let lamp = try #require(source.devices.first { $0.name == "String lights" })
        source.setAttention(.background, device: lamp)
        source.setPriority(.low, room: "Garage"); source.smartOrder = false
        source.recordRoomUse("Bedroom")
        let data = try source.exportLayout()
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["lastUsed", "lastCounted", "frequency", "roomUse"] { #expect(!text.contains(forbidden)) }
        let target = HomeModel(preferences: nil)
        try target.importLayout(data)
        #expect(target.roomPriorities["Garage"] == .low)
        #expect(target.placements[lamp.id]?.attention == .background)
        #expect(!target.smartOrder); #expect(target.roomUse.isEmpty)
        let legacy = Data(#"{"format":"vesta-home-layout","version":1,"rooms":[],"placements":{},"celsius":false}"#.utf8)
        try target.importLayout(legacy)
        #expect(target.roomPriorities["Garage"] == .low); #expect(!target.smartOrder)
        source.savedRooms = ["Garage"]; source.setPriority(.automatic, room: "Garage")
        try target.importLayout(source.exportLayout())
        #expect(target.roomPriorities["Garage"] == .automatic)
        var invalid = try HomeLayoutFile.decode(data); invalid.roomPriorities = ["Bad\nroom": .low]
        #expect(throws: (any Error).self) { try invalid.encoded() }
    }
    @Test func corruptOrFutureUsageCannotPromoteRooms() throws {
        let name = "RoomAttentionTests." + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name)); defer { prefs.removePersistentDomain(forName: name) }
        let entries = ["Future": use(date.addingTimeInterval(86400)), "Invalid": use(date, frequency: 1000), "Good": use(date)]
        prefs.set(try JSONEncoder().encode(entries), forKey: "home.roomUse.v1")
        let model = HomeModel(preferences: prefs, now: { date })
        #expect(Set(model.roomUse.keys) == ["Good"])
    }
}
