import AppKit
import SwiftUI
import LumoKit

/// Owns the menu-bar item and its popover.
///
/// This replaces `MenuBarExtra(.window)`, which could not keep the popover anchored
/// to the status item. Its panel lays out new content one pass before the window
/// follows and draws the difference centred, so any height change — dragging a
/// resize grabber, or simply expanding a light's controls — made the popover grow
/// from the top and bottom at once and left it detached from the menu bar.
///
/// `NSPopover` is built for exactly this: it is bound to a positioning view and
/// grows from the anchored edge when `contentSize` changes. It also supplies the
/// standard popover material, so the content sits on a real system background
/// rather than a plain fill.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model: AppModel
    private var observation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon(lit: false)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.setAccessibilityLabel("Lumo")

        popover.behavior = .transient          // closes when you click away
        popover.animates = false               // no size animation to fight
        popover.delegate = self
        let controller = NSHostingController(rootView: MenuBarView(model: model))
        // Without this the hosting controller never reports a preferred size, so
        // NSPopover sizes itself from a default and positions *that* — then SwiftUI
        // lays the content out afterwards and the popover is left anchored to a size
        // it no longer has. That is why it appeared mid-screen on first open and
        // hung off the top of the screen on reopen, when the content was already big.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        // The menu-bar icon reflects the room at a glance.
        startWatchingLights()
    }

    private static func icon(lit: Bool) -> NSImage? {
        NSImage(systemSymbolName: lit ? "lightbulb.fill" : "lightbulb",
                accessibilityDescription: "Lumo")
    }

    /// Polls the store rather than observing it: `@Observable` needs a SwiftUI
    /// context to track, and this lives in AppKit. One cheap check a second is
    /// nothing next to the network traffic the bridge transport already does.
    private func startWatchingLights() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lit = self.model.store.anyLightOn
                let image = Self.icon(lit: lit)
                image?.isTemplate = true
                if self.statusItem.button?.image?.name() != image?.name() {
                    self.statusItem.button?.image = image
                }
            }
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            close()
        } else {
            show()
        }
    }

    private func show() {
        guard let button = statusItem.button else { return }
        // .minY hangs the popover *below* the status item. .maxY anchors it off
        // the button's top edge, which for an item in the menu bar puts the
        // popover above the screen — covering the menu bar with only its lower
        // half visible.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Bring the app forward so the popover takes key focus, matching how
        // Control Center and other menu-bar popovers behave.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        startWatchingForOutsideClicks()
    }

    private func close() {
        stopWatchingForOutsideClicks()
        popover.performClose(nil)
    }

    /// Closes the popover when you click anywhere else, the way every other menu-bar
    /// popover behaves.
    ///
    /// `NSPopover.transient` alone is not enough here. It dismisses on interaction
    /// *within the same application*, but Lumo is an accessory app that owns no
    /// ordinary windows — click into Safari or the Finder and those events never
    /// reach it, so the popover just stays up. A global monitor sees mouse-downs
    /// destined for other apps; the local one covers clicks on Lumo's own menu bar
    /// item and any other window it may own.
    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // A global monitor never sees events delivered to this app, so resigning key
        // covers the rest: clicking another Lumo surface, or Mission Control taking
        // over, both dismiss it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: popover.contentViewController?.view.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}
