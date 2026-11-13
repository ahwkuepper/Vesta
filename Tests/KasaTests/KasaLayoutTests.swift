// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Testing
import SwiftUI
import AppKit
import KasaKit
import VestaDesign
@testable import KasaUI

@Suite("Shared Vesta popover layout", .serialized)
@MainActor
struct KasaLayoutTests {
    private func measure<V: View>(_ view: V) -> CGSize {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: view.frame(width: MenuMetrics.width))
        return host.sizeThatFits(in: CGSize(width: MenuMetrics.width, height: 10_000))
    }

    @Test("Short content takes its natural height on its first layout")
    func shortList() {
        let size = measure(PopoverList(maximumHeight: 500) { Color.clear.frame(height: 120) })
        #expect(size.width == 330)
        #expect(abs(size.height - 120) < 1)
    }

    @Test("Long content is constrained to the screen without a provisional frame")
    func longList() {
        let size = measure(PopoverList(maximumHeight: 500) { Color.clear.frame(height: 1000) })
        #expect(size.width == 330)
        #expect(abs(size.height - 500) < 1)
    }

    @Test("Identical content has identical first-open and reopened dimensions")
    func repeatLayout() {
        let model = KasaModel(demo: true)
        let first = measure(KasaMenuView(model: model))
        let reopened = measure(KasaMenuView(model: model))
        #expect(first.width == 330)
        #expect(first == reopened)
        #expect(first.height > 400)
        #expect(first.height < 850)
    }

    @Test("A reconnect leaves a known bulb's controls and row height in place")
    func reconnect() {
        let model = KasaModel(demo: true)
        var bulb = model.devices[0]
        let ready = measure(KasaDeviceRow(device: bulb, model: model, isExpanded: .constant(false)))
        bulb.connection = .offline
        let offline = measure(KasaDeviceRow(device: bulb, model: model, isExpanded: .constant(false)))
        #expect(ready == offline)
    }

    @Test("Refreshing does not insert header controls or change the popover frame")
    func refresh() {
        let model = KasaModel(demo: true)
        let idle = measure(KasaMenuView(model: model))
        model.isRefreshing = true
        let refreshing = measure(KasaMenuView(model: model))
        #expect(idle == refreshing)
    }

    @Test("Expanded schedules and their editor remain within the screen cap")
    func scheduleExpansion() async throws {
        let model = KasaModel(demo: true)
        let device = try #require(model.devices.first)
        await model.loadSchedules(for: device)
        let list = measure(KasaMenuView(model: model, scheduleIDs: [device.id]))
        model.beginScheduleEdit(for: device)
        let editor = measure(KasaMenuView(model: model, scheduleIDs: [device.id]))
        let maximum = NSScreen.main?.visibleFrame.height ?? 900
        #expect(list.width == 330)
        #expect(editor.width == 330)
        #expect(list.height < maximum)
        #expect(editor.height < maximum)
        #expect(editor.height > 400)
    }

    @Test("Sign-in and error messages cannot push the whole popover beyond the screen", arguments: [350.0, 600.0, 765.0, 1000.0])
    func authenticationOverflow(budget: Double) {
        let model = KasaModel(demo: true)
        let prototype = model.devices[0]
        model.devices = (0..<24).map { index in
            var device = prototype; device.id = "fixture-\(index)"
            device.connection = .signInRequired
            return device
        }
        model.error = String(repeating: "The account could not be accessed. ", count: 20)
        let size = measure(KasaMenuView(model: model, scheduleIDs: [model.devices[0].id], availableHeight: budget))
        #expect(abs(size.height - budget) < 0.5)
        #expect(size.width == 330)
    }

    @Test("The whole page reserves its header and scrolls everything below it")
    func pageBudget() {
        let short = measure(PopoverPage(maximumHeight: 500) {
            Color.clear.frame(height: 60)
        } content: { Color.clear.frame(height: 120) })
        let long = measure(PopoverPage(maximumHeight: 500) {
            Color.clear.frame(height: 60)
        } content: { Color.clear.frame(height: 1000) })
        #expect(short.height == 180)
        #expect(long.height == 500)
    }

    @Test("Available space follows the anchor display with positive or negative desktop origins")
    func anchorScreen() {
        for origin in [-1080.0, 0, 1080] {
            let visible = CGRect(x: 1920, y: origin + 40, width: 1440, height: 836)
            let anchor = CGRect(x: 2500, y: origin + 876, width: 24, height: 24)
            #expect(PopoverPlacement.maximumContentHeight(anchor: anchor, visibleFrame: visible) == 804)
        }
        let tiny = PopoverPlacement.maximumContentHeight(anchor: CGRect(x: 0, y: 220, width: 24, height: 24),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 220))
        #expect(tiny == 188) // Never impose a minimum height larger than the screen.
    }

    @Test("Reopening an expanded editor after moving to a smaller screen respects the new budget")
    func smallerDisplay() async throws {
        let model = KasaModel(demo: true)
        let device = try #require(model.devices.first)
        await model.loadSchedules(for: device)
        model.beginScheduleEdit(for: device)
        let host = NSHostingController(rootView: KasaMenuView(model: model, scheduleIDs: [device.id], availableHeight: 900))
        let proposal = CGSize(width: 330, height: 10_000)
        let large = host.sizeThatFits(in: proposal)
        host.rootView.availableHeight = 450
        let small = host.sizeThatFits(in: proposal)
        #expect(large.height <= 900)
        #expect(small.height == 450)
        #expect(small.width == 330)
        #expect(model.scheduleEdits[device.id] != nil)
    }

    @Test("Colour control drafts coalesce while the slider keeps its latest value")
    func temperatureDraft() async throws {
        let model = KasaModel(demo: true)
        let bulb = try #require(model.devices.first { $0.supportsTemperature })
        model.setControl(.temperature(3000), for: bulb)
        model.setControl(.temperature(4000), for: bulb)
        #expect(model.controlDraft[bulb.id] == .temperature(4000))
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.devices.first { $0.id == bulb.id }?.colorTemperature == 4000)
        #expect(model.controlDraft[bulb.id] == nil)
    }
}
