import Testing
import SwiftUI
import AppKit
import VestaDesign
@testable import HomePreviewUI

@Suite("Unified Home preview", .serialized) @MainActor
struct HomePreviewTests {
    @Test func lampPlugsAndBulbsShareLights() {
        let model = HomeModel()
        #expect(model.lights.contains { $0.isPlug })
        #expect(model.lights.contains { $0.source == .hue })
        #expect(model.lights.contains { $0.source == .kasa && !$0.isPlug })
        #expect(!model.lights.contains { $0.id == "charger" })
        #expect(model.lights.filter(\.isPlug).allSatisfy { $0.brightness == nil })
    }
    @Test func allLightsDoesNotToggleAppliancesOrUnavailableDevices() throws {
        let model = HomeModel()
        let charger = try #require(model.devices.first { $0.id == "charger" })
        let offline = try #require(model.devices.first { !$0.reachable })
        model.toggleAll(false)
        #expect(model.devices.first { $0.id == charger.id }?.isOn == charger.isOn)
        #expect(model.devices.first { $0.id == offline.id }?.isOn == offline.isOn)
        #expect(model.lights.filter(\.reachable).allSatisfy { !$0.isOn })
        model.toggleAll(true, room: "Bedroom")
        #expect(model.lights.filter { $0.room == "Bedroom" }.allSatisfy { $0.isOn })
        #expect(model.lights.filter { $0.room != "Bedroom" && $0.reachable }.allSatisfy { !$0.isOn })
    }
    @Test func plugClassificationChangesGroupControl() {
        let model = HomeModel()
        model.change("reading") { $0.category = .devices }
        model.toggleAll(false)
        #expect(model.otherDevices.contains { $0.id == "reading" && $0.isOn })
        model.change("reading") { $0.category = .lights }
        model.toggleAll(false)
        #expect(model.lights.contains { $0.id == "reading" && !$0.isOn })
    }
    @Test func scenesRespectCapabilities() {
        let model = HomeModel()
        model.scene("Evening")
        #expect(model.devices.first { $0.id == "reading" }?.brightness == nil)
        #expect(model.devices.first { $0.id == "sofa" }?.brightness == 35)
        #expect(model.devices.first { $0.id == "sofa" }?.warmth == 2400)
        #expect(model.devices.first { $0.id == "porch-left" }?.warmth == 2700)
        #expect(model.devices.first { $0.id == "guest" }?.isOn == false)
    }
    @Test func temperatureUnitsAndBounds() {
        let model = HomeModel()
        model.target = 68; model.celsius = true
        #expect(model.targetLabel == "20°")
        model.stepTarget(1)
        #expect(model.targetLabel == "21°")
        model.stepTarget(100); #expect(model.target == 85)
        model.stepTarget(-100); #expect(model.target == 50)
        model.target = 80; #expect(model.heating)
        model.eco = true; #expect(!model.heating)
        model.heatEnabled = false; #expect(model.climateStatus == "Off")
    }
    @Test func detailsSurviveLayoutSwitchAndRoomChanges() {
        let model = HomeModel()
        model.expandedDevices = ["sofa"]; model.climateExpanded = true
        model.change("sofa") { $0.room = "Bedroom" }
        for layout in HomeLayout.allCases {
            model.selectedLayout = layout
            #expect(model.expandedDevices.contains("sofa"))
            #expect(model.climateExpanded)
            #expect(model.devices.first { $0.id == "sofa" }?.room == "Bedroom")
        }
        model.reset()
        #expect(model.expandedDevices.isEmpty)
        #expect(!model.climateExpanded)
    }
    @Test("Every layout stays within the popover budget", arguments: [350.0, 600.0, 760.0])
    func cappedLayout(budget: Double) {
        _ = NSApplication.shared
        let model = HomeModel()
        model.climateExpanded = true; model.expandedDevices = ["sofa", "porch-left", "reading"]
        for layout in HomeLayout.allCases {
            let host = NSHostingController(rootView: HomeView(model: model, layout: layout, maximumHeight: budget))
            let first = host.sizeThatFits(in: CGSize(width: 330, height: 10000))
            let second = host.sizeThatFits(in: CGSize(width: 330, height: 10000))
            #expect(first.width == 330)
            #expect(first.height <= budget + 0.5)
            #expect(first == second)
        }
    }
    @Test func searchFindsRoomsAcrossVendors() {
        let model = HomeModel(); model.search = "Living"
        let found = model.filtered(model.devices)
        #expect(found.count == 3)
        #expect(Set(found.map(\.source)).count == 2)
    }
}
