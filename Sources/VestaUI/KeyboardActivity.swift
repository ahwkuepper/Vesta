// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// Whether the person is currently driving the app from the keyboard.
///
/// A focus ring is essential when someone is tabbing through controls and noise
/// when they are not. macOS resolves this for its own controls by only drawing focus
/// rings under Full Keyboard Access; a custom control has to decide for itself.
///
/// So the ring appears when the keyboard is actually in use — a key pressed while
/// the popover is open, or the popover opened from the keyboard in the first place —
/// and fades out again once the keyboard has been idle for a few seconds. Pointer
/// users never see it.
@MainActor
@Observable
final class KeyboardActivity {

    static let shared = KeyboardActivity()

    private(set) var isActive = false

    /// How long the ring stays after the last keystroke. Long enough to survive
    /// thinking between two arrow presses, short enough not to linger.
    private static let idleTimeout = Duration.seconds(4)

    private var idleTask: Task<Void, Never>?

    private init() {}

    /// A key was pressed. Shows the ring and restarts the idle countdown.
    func noteKeyboardUse() {
        isActive = true
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }

    /// The popover closed, or opened by pointer. Nothing is being typed at.
    func reset() {
        idleTask?.cancel()
        idleTask = nil
        isActive = false
    }
}

/// Watches for key presses while the popover is open.
///
/// A local monitor rather than SwiftUI's `onKeyPress`: the ring has to react to any
/// keystroke anywhere in the popover, including Tab moving focus between controls,
/// not only to keys a particular control handles.
@MainActor
final class KeyboardActivityMonitor {

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { KeyboardActivity.shared.noteKeyboardUse() }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        KeyboardActivity.shared.reset()
    }
}

private struct KeyboardActivityKey: EnvironmentKey {
    static let defaultValue = MainActor.assumeIsolated { KeyboardActivity.shared }
}

extension EnvironmentValues {
    /// Injected rather than reached for, so a view can be rendered with keyboard
    /// activity forced on or off — the snapshot renderer wants it off.
    var keyboardActivity: KeyboardActivity {
        get { self[KeyboardActivityKey.self] }
        set { self[KeyboardActivityKey.self] = newValue }
    }
}
