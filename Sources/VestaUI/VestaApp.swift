// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import VestaDesign
import AppKit

/// The app is AppKit-hosted rather than using `MenuBarExtra`.
///
/// `MenuBarExtra(.window)` could not keep its popover anchored to the status item
/// across content-size changes; `StatusItemController` uses `NSStatusItem` plus
/// `NSPopover`, which is designed for it. The SwiftUI view hierarchy is unchanged.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController(model: model)
        Task { await model.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return false
    }
}

public enum VestaApp {
    /// The only entry point the executable needs.
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        // Do this before AppModel reads credentials or starts any transport.
        // Bundle identity also catches older installed copies without the lock.
        let identifier = "io.github.ahwkuepper.Vesta"
        let current = NSRunningApplication.current
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
            .filter {
                let date = $0.launchDate ?? .distantPast
                let currentDate = current.launchDate ?? .distantFuture
                return date < currentDate || (date == currentDate && $0.processIdentifier < current.processIdentifier)
            }
            .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        if let other {
            other.activate(options: [])
            return
        }
        let instanceLock: InstanceLock
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Vesta", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let acquired = try InstanceLock.acquire(at: directory.appendingPathComponent("instance.lock")) else {
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first { $0.processIdentifier != current.processIdentifier }?
                    .activate(options: [])
                return
            }
            instanceLock = acquired
        } catch {
            let alert = NSAlert()
            alert.messageText = "Vesta couldn’t start"
            alert.informativeText = "The single-instance lock could not be opened. \(error.localizedDescription)"
            alert.runModal()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        // Held for the process lifetime; NSApplication does not retain its delegate.
        objc_setAssociatedObject(app, "vesta.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        withExtendedLifetime(instanceLock) { app.run() }
    }
}
