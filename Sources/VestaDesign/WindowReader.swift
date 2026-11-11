// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// Hands the popover's `NSWindow` to SwiftUI, so the view can measure how much room
/// there is beneath the status item before deciding how tall to be.
public struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    public init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}
