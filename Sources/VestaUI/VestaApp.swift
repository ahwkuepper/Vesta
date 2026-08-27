import SwiftUI
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
}

public enum VestaApp {
    /// The only entry point the executable needs.
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Held for the process lifetime; NSApplication does not retain its delegate.
        objc_setAssociatedObject(app, "vesta.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
