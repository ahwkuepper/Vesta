// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import VestaKit

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
    private let keyboardMonitor = KeyboardActivityMonitor()
    private var isShowingLitIcon = false
    /// When the popover was last closed programmatically — see `toggle()`.
    private var lastProgrammaticClose: ContinuousClock.Instant?

    init(model: AppModel) {
        self.model = model
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon(lit: false)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.setAccessibilityLabel("Vesta")

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
                accessibilityDescription: "Vesta")
    }

    /// Polls the store rather than observing it: `@Observable` needs a SwiftUI
    /// context to track, and this lives in AppKit. One cheap check a second is
    /// nothing next to the network traffic the bridge transport already does.
    ///
    /// The lit state is tracked here rather than read back off the button. An
    /// `NSImage` built with `systemSymbolName:` is not a named image — `name()`
    /// returns nil for every SF Symbol — so comparing the two names compared nil to
    /// nil, was never unequal, and the icon never changed at all.
    private func startWatchingLights() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lit = self.model.store.anyLightOn
                guard lit != self.isShowingLitIcon else { return }
                self.isShowingLitIcon = lit
                let image = Self.icon(lit: lit)
                image?.isTemplate = true
                self.statusItem.button?.image = image
            }
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            close()
            return
        }
        // Clicking the icon while the popover is open first makes its window resign
        // key, which closes it through the observer below — so by the time this
        // action runs the popover is already gone and a naive `else` would reopen
        // it. Worse, that reopen races the close and lands against a status item
        // mid-transition, which is how the popover ends up beside its icon instead
        // of under it. A click that merely dismissed the popover does nothing more.
        if let closedAt = lastProgrammaticClose,
           ContinuousClock.now - closedAt < .milliseconds(250) {
            lastProgrammaticClose = nil
            return
        }
        show()
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

        // Opened from the keyboard? Then show focus straight away. Opened by click,
        // and the ring stays hidden until a key is actually pressed.
        if let event = NSApp.currentEvent, event.type == .keyDown {
            KeyboardActivity.shared.noteKeyboardUse()
        } else {
            KeyboardActivity.shared.reset()
        }
        keyboardMonitor.start()
    }

    private func close() {
        guard popover.isShown else { return }
        lastProgrammaticClose = .now
        stopWatchingForOutsideClicks()
        keyboardMonitor.stop()
        popover.performClose(nil)
    }

    /// Closes the popover when you click anywhere else, the way every other menu-bar
    /// popover behaves.
    ///
    /// `NSPopover.transient` alone is not enough here. It dismisses on interaction
    /// *within the same application*, but Vesta is an accessory app that owns no
    /// ordinary windows — click into Safari or the Finder and those events never
    /// reach it, so the popover just stays up. A global monitor sees mouse-downs
    /// destined for other apps; the local one covers clicks on Vesta's own menu bar
    /// item and any other window it may own.
    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // A global monitor never sees events delivered to this app, so resigning key
        // covers the rest: clicking another Vesta surface, or Mission Control taking
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
