import Testing
import Foundation
import SwiftUI
import AppKit
import VestaKit
import NestCore
import KasaUI
@testable import HomeUI

@Suite("Vesta Home", .serialized) @MainActor
struct HomeTests {
    @Test func plugClassificationIsConservative() {
        #expect(HomeModel.inferredKind(name: "Bedroom Light", isPlug: true) == .light)
        #expect(HomeModel.inferredKind(name: "Car charger", isPlug: true) == .device)
        #expect(HomeModel.inferredKind(name: "Fan", isPlug: true) == .device)
        #expect(HomeModel.inferredKind(name: "Daylight charger", isPlug: true) == .device)
        #expect(HomeModel.inferredKind(name: "Porch", isPlug: false) == .light)
    }
    @Test func unitsAndMissingValues() {
        let model = HomeModel(preferences: nil)
        #expect(model.temperatureLabel(nil) == "—")
        #expect(model.temperatureLabel(20) == "68°")
        model.celsius = true
        #expect(model.temperatureLabel(20) == "20.0°")
        #expect(!model.climateWritable)
        #expect(model.devices.isEmpty)
    }
    @Test func roomPersistence() throws {
        let name = "VestaHomeTests." + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let first = HomeModel(preferences: prefs)
        first.roomDraft = "  Living room  "; first.addRoom(); first.celsius = true
        let second = HomeModel(preferences: prefs)
        #expect(second.rooms == ["Living room"])
        #expect(second.celsius)
    }
    @Test func assignmentsSurviveRelaunchAndGroupPowerExcludesAppliances() async throws {
        let name = "VestaHomeTests." + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let first = HomeModel(preferences: prefs, kasa: KasaHome(demo: true))
        let lamp = try #require(first.devices.first { $0.name == "Bedroom lamp" })
        first.assign(lamp, room: "Bedroom", kind: .device)
        first.allLights(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(first.devices.first { $0.id == lamp.id }?.isOn == true)
        #expect(first.devices.first { $0.name == "Charger" }?.isOn == true)
        #expect(first.devices.filter { $0.kind == .light }.allSatisfy { !$0.isOn })
        let second = HomeModel(preferences: prefs, kasa: KasaHome(demo: true))
        #expect(second.devices.first { $0.id == lamp.id }?.room == "Bedroom")
        #expect(second.devices.first { $0.id == lamp.id }?.kind == .device)
        second.assign(lamp, kind: .light)
        second.allLights(false, room: "Bedroom")
        try await Task.sleep(for: .milliseconds(30))
        #expect(second.devices.first { $0.id == lamp.id }?.isOn == false)
        #expect(second.devices.first { $0.name == "Charger" }?.isOn == true)
    }
    @Test func roomSuggestionsPreferSpecificWordMatches() {
        #expect(HomeModel.suggestedRoom(name: "Guest Bedroom Light", rooms: ["Bedroom", "Guest Bedroom"]) == "Guest Bedroom")
        #expect(HomeModel.suggestedRoom(name: "Nursery Light", rooms: ["Nursery"]) == "Nursery")
        #expect(HomeModel.suggestedRoom(name: "Bedroomish", rooms: ["Bedroom"]) == "Unassigned")
    }
    @Test func constrainedLayout() {
        _ = NSApplication.shared
        let model = HomeModel(preferences: nil, kasa: KasaHome(demo: true))
        model.climateExpanded = true
        model.expanded = Set(model.devices.map(\.id))
        for settings in [false, true] {
            model.settings = settings
            for budget in [350.0, 600.0, 760.0] {
                let host = NSHostingController(rootView: HomeView(model: model, maximumHeight: budget))
                let size = host.sizeThatFits(in: CGSize(width: 330, height: 10000))
                #expect(size.width == 330); #expect(size.height <= budget + 0.5)
            }
        }
    }
    @Test func portableLayoutRoundTripMergesAndPersistsWithoutDeviceState() throws {
        let source = HomeModel(preferences: nil, kasa: KasaHome(demo: true))
        let lamp = try #require(source.devices.first { $0.name == "Bedroom lamp" })
        source.assign(lamp, room: "Bedroom", kind: .light)
        source.roomDraft = "Bedroom"; source.addRoom(); source.celsius = true
        let exported = try source.exportLayout()
        let text = String(decoding: exported, as: UTF8.self)
        for forbidden in ["password", "refreshToken", "clientSecret", "host", "isOn", "brightness"] {
            #expect(!text.contains(forbidden))
        }
        let name = "VestaHomeTests." + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name)); defer { prefs.removePersistentDomain(forName: name) }
        let target = HomeModel(preferences: prefs, kasa: KasaHome(demo: true))
        target.roomDraft = "Office"; target.addRoom()
        try target.importLayout(exported)
        let reopened = HomeModel(preferences: prefs, kasa: KasaHome(demo: true))
        #expect(reopened.savedRooms == ["Bedroom", "Office"])
        #expect(reopened.celsius)
        #expect(reopened.devices.first { $0.id == lamp.id }?.room == "Bedroom")
        #expect(reopened.devices.first { $0.id == lamp.id }?.isOn == lamp.isOn)
    }
    @Test func invalidLayoutNeverChangesSettings() throws {
        let model = HomeModel(preferences: nil)
        model.roomDraft = "Keep this room"; model.addRoom()
        let before = try model.exportLayout()
        var unsupported = HomeLayoutFile(rooms: ["Other"], placements: [:], celsius: true)
        unsupported.version = 999
        let unknownVersion = try JSONEncoder().encode(unsupported)
        let huge = Data(repeating: 32, count: HomeLayoutFile.byteLimit + 1)
        let badName = try JSONEncoder().encode(HomeLayoutFile(rooms: ["Bad\nroom"], placements: [:], celsius: true))
        for invalid in [unknownVersion, huge, badName, Data(#"{"web":{"client_secret":"synthetic"}}"#.utf8)] {
            #expect(throws: (any Error).self) { try model.importLayout(invalid) }
            #expect(try model.exportLayout() == before)
        }
    }
}
