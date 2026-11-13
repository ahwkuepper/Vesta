import AppKit
import SwiftUI
import VestaDesign

struct ComparisonView: View {
    @Bindable var model: HomeModel
    var select: (HomeLayout) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("One home. Three ways in.").font(.largeTitle.weight(.semibold))
                    Text("Try the controls. Changes are shared across the layouts; all devices are samples.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset preview") { model.reset() }.controlSize(.small)
            }
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(HomeLayout.allCases) { layout in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(layout.title).font(.headline)
                                if layout == .rooms { Text("Suggested").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(layout.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            HomeView(model: model, layout: layout, maximumHeight: 600, choose: select)
                                .frame(width: MenuMetrics.width, height: 600, alignment: .top)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.09), lineWidth: 0.5))
                            Button {
                                model.selectedLayout = layout
                                select(layout)
                            } label: {
                                Label("Try \(layout.title.lowercased()) in menu bar", systemImage: "menubar.arrow.up.rectangle")
                                    .frame(maxWidth: .infinity)
                            }.controlSize(.large)
                        }.frame(width: MenuMetrics.width)
                    }
                }.padding(.bottom, 8)
            }
            Text("Start with rooms for everyday use. Quick access favors frequent controls; tabs keep devices separate from lights.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 390, idealWidth: 1082, minHeight: 500, idealHeight: 810)
    }
}

@MainActor final class HomeController: NSObject, NSPopoverDelegate {
    let model = HomeModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var hosting: NSHostingController<HomeView>?
    private var comparison: NSWindow?
    private var outside: Any?
    private var resigned: NSObjectProtocol?
    private var displayChanged: NSObjectProtocol?
    private var closedAt: ContinuousClock.Instant?

    override init() {
        super.init()
        model.selectedLayout = HomeLayout(rawValue: UserDefaults.standard.string(forKey: "preview.layout") ?? "") ?? .rooms
        item.button?.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Vesta Home Preview")
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Vesta Home Preview")
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        let host = NSHostingController(rootView: makeView(maximum: 640))
        host.sizingOptions = [.preferredContentSize]
        hosting = host; popover.contentViewController = host
        displayChanged = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    private func makeView(maximum: CGFloat) -> HomeView {
        HomeView(model: model, layout: model.selectedLayout, maximumHeight: maximum,
                 compare: { [weak self] in self?.showComparison() }, choose: { [weak self] layout in self?.select(layout) })
    }

    func select(_ layout: HomeLayout) {
        model.selectedLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: "preview.layout")
        measure()
        if !popover.isShown { show() }
    }

    @objc private func toggle() {
        if popover.isShown { close(); return }
        if let closedAt, ContinuousClock.now - closedAt < .milliseconds(250) { self.closedAt = nil; return }
        show()
    }

    func show() {
        guard !popover.isShown, let button = item.button else { return }
        measure()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                           object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func measure() {
        guard let button = item.button, let window = button.window, let screen = window.screen, let hosting else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let maximum = max(1, min(anchor.minY, screen.visibleFrame.maxY) - screen.visibleFrame.minY - 32)
        hosting.rootView = makeView(maximum: maximum)
        let size = hosting.sizeThatFits(in: CGSize(width: MenuMetrics.width, height: maximum))
        let bounded = CGSize(width: MenuMetrics.width, height: min(maximum, size.height))
        hosting.preferredContentSize = bounded; popover.contentSize = bounded
        hosting.view.layoutSubtreeIfNeeded()
    }

    private func close() { if popover.isShown { popover.performClose(nil) } }
    func popoverDidClose(_ notification: Notification) {
        closedAt = .now
        if let outside { NSEvent.removeMonitor(outside); self.outside = nil }
        if let resigned { NotificationCenter.default.removeObserver(resigned); self.resigned = nil }
    }

    func showComparison() {
        close()
        if let comparison { comparison.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1090, screen.width - 60), height: min(820, screen.height - 60)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Vesta Home — Layout Preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ComparisonView(model: model, select: { [weak self] layout in self?.select(layout) }))
        window.center(); window.makeKeyAndOrderFront(nil)
        comparison = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor final class HomeDelegate: NSObject, NSApplicationDelegate {
    var controller: HomeController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = HomeController()
        controller?.showComparison()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showComparison(); return false
    }
}

public enum HomePreviewApp {
    @MainActor public static func run() {
        let app = NSApplication.shared
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.ahwkuepper.VestaHomePreview")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first { other.activate(options: []); return }
        let delegate = HomeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
