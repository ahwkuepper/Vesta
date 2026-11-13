// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Uses the status item's display, never the popover's resulting display or the
/// main display. Those can differ on a multi-monitor desktop or after undocking.
enum PopoverPlacement {
    static let chromeAllowance: CGFloat = 32

    static func maximumContentHeight(anchor: CGRect, visibleFrame: CGRect) -> CGFloat {
        max(1, min(anchor.minY, visibleFrame.maxY) - visibleFrame.minY - chromeAllowance)
    }
}
