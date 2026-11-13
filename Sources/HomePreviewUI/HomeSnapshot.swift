import AppKit
import SwiftUI
import VestaDesign

public enum HomeSnapshot {
    @MainActor public static func render(to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = GlassSettings.isEnabled
        GlassSettings.isEnabled = false
        defer { GlassSettings.isEnabled = previous }
        for dark in [false, true] {
            try capture(ComparisonView(model: HomeModel(), select: { _ in }),
                        size: CGSize(width: 1100, height: 850), dark: dark,
                        url: directory.appendingPathComponent("comparison-\(dark ? "dark" : "light").png"))
            for layout in HomeLayout.allCases {
                let model = HomeModel()
                try capture(HomeView(model: model, layout: layout, maximumHeight: 660),
                            size: CGSize(width: 330, height: 660), dark: dark,
                            url: directory.appendingPathComponent("\(layout.rawValue)-\(dark ? "dark" : "light").png"))
            }
            let expanded = HomeModel(); expanded.climateExpanded = true; expanded.expandedDevices = ["sofa"]
            try capture(HomeView(model: expanded, layout: .rooms, maximumHeight: 760),
                        size: CGSize(width: 330, height: 760), dark: dark,
                        url: directory.appendingPathComponent("expanded-\(dark ? "dark" : "light").png"))
        }
    }

    @MainActor private static func capture<V: View>(_ view: V, size: CGSize, dark: Bool, url: URL) throws {
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1))))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            hosting.frame.size = size; hosting.layoutSubtreeIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
