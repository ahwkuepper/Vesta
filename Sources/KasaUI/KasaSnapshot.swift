// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import VestaDesign
import KasaKit
import AppKit

@MainActor
public enum KasaSnapshot {
    public static func renderSchedules(to directory: URL) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = GlassSettings.isEnabled
        GlassSettings.isEnabled = false
        defer { GlassSettings.isEnabled = previous }
        let model = KasaModel(demo: true)
        guard let device = model.devices.first else { return }
        await model.loadSchedules(for: device)
        try renderSchedulePanels(model: model, device: device, directory: directory)
    }

    private static func renderSchedulePanels(model: KasaModel, device: KasaDevice, directory: URL) throws {
        for editing in [false, true] {
            if editing { model.beginScheduleEdit(for: device) }
            let view = KasaScheduleView(device: device, model: model)
                .padding(18).frame(width: 330)
                .environment(\.colorScheme, .dark)
                .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            for _ in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                hosting.frame.size = hosting.fittingSize
                hosting.layoutSubtreeIfNeeded()
            }
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: directory.appendingPathComponent(editing ? "schedule-editor.png" : "schedules.png"))
        }
    }

    public static func render(to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let model = KasaModel(demo: true)
            let view = KasaMenuView(model: model, snapshot: true)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            for _ in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                hosting.frame.size = hosting.fittingSize
                hosting.layoutSubtreeIfNeeded()
            }
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: directory.appendingPathComponent(dark ? "kasa-dark.png" : "kasa-light.png"))
        }
    }
}
