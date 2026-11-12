import AppKit
import SwiftUI
import VestaDesign

@MainActor final class HomeController: NSObject, NSPopoverDelegate {
    let model = HomeModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var hosting: NSHostingController<HomeView>?
    private var outside: Any?
    private var resigned: NSObjectProtocol?
    private var displayChanged: NSObjectProtocol?
    private var closedAt: ContinuousClock.Instant?
    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Vesta Home")
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Vesta Home")
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        let host = NSHostingController(rootView: HomeView(model: model))
        host.sizingOptions = [.preferredContentSize]
        hosting = host; popover.contentViewController = host
        displayChanged = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }
    @objc private func toggle() {
        if popover.isShown { close(); return }
        if let closedAt, ContinuousClock.now - closedAt < .milliseconds(250) { self.closedAt = nil; return }
        show()
    }
    func show() {
        guard !popover.isShown, let button = item.button else { return }
        model.beginPresentation()
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
        Task { await model.opened() }
    }
    private func measure() {
        guard let button = item.button, let window = button.window, let screen = window.screen, let hosting else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let maximum = max(1, min(anchor.minY, screen.visibleFrame.maxY) - screen.visibleFrame.minY - 32)
        hosting.rootView = HomeView(model: model, maximumHeight: maximum)
        let size = hosting.sizeThatFits(in: CGSize(width: MenuMetrics.width, height: maximum))
        let bounded = CGSize(width: MenuMetrics.width, height: min(maximum, size.height))
        hosting.preferredContentSize = bounded; popover.contentSize = bounded
        hosting.view.layoutSubtreeIfNeeded()
    }
    private func close() { if popover.isShown { popover.performClose(nil) } }
    func popoverDidClose(_ notification: Notification) {
        model.endPresentation()
        closedAt = .now
        if let outside { NSEvent.removeMonitor(outside); self.outside = nil }
        if let resigned { NotificationCenter.default.removeObserver(resigned); self.resigned = nil }
    }
}

@MainActor final class HomeDelegate: NSObject, NSApplicationDelegate {
    var controller: HomeController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = HomeController(); self.controller = controller
        controller.show()
        Task { await controller.model.start() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show(); return false
    }
}

public enum VestaHomeApp {
    @MainActor public static func run() {
        let app = NSApplication.shared
        let identifier = "io.github.ahwkuepper.VestaHome"
        let current = NSRunningApplication.current
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }) {
            other.activate(options: []); return
        }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            guard let lock = try InstanceLock.acquire(at: directory.appendingPathComponent("vesta-home.lock")) else { return }
            let delegate = HomeDelegate(); app.delegate = delegate
            withExtendedLifetime((delegate, lock)) { app.run() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Vesta Home couldn’t start"
            alert.informativeText = "The app’s single-instance lock could not be opened. " + error.localizedDescription
            alert.runModal()
        }
    }
}
