// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The app's type scale, named by what each role does rather than by point size.
///
/// Every one of these is built on a `Font.TextStyle`, so it responds to the system
/// text size instead of being pinned to a literal. Thirty-four hard-coded
/// `.system(size:)` calls meant a low-vision user got no relief in-app whatever they
/// set: the smallest and most information-dense text — chip labels, section captions
/// — stayed at nine or ten points forever.
///
/// The popover is a fixed 330pt wide and several names are `lineLimit(1)`, so growth
/// is clamped at the root rather than left unbounded; see `dynamicTypeClamped()`.
/// The sizes noted below are what each style measures at the default setting, which
/// is what the previous literals were.
extension Font {

    // MARK: - Header

    /// The status-item glyph beside the app name.
    static let appGlyph = Font.title3                          // 15

    /// "Vesta".
    static let appTitle = Font.headline                        // 13 semibold

    /// "2 of 2 on" beneath it.
    static let appSummary = Font.subheadline                   // 11

    // MARK: - Rooms and lights

    static let roomName = Font.callout.weight(.semibold)       // 12
    static let roomIcon = Font.callout                         // 12
    /// "3/5" beside a room name.
    static let roomCount = Font.footnote                       // 10

    static let lightName = Font.body.weight(.medium)           // 13
    /// "72%", "Off", "Unreachable".
    static let lightStatus = Font.subheadline                  // 11
    static let lightStatusEmphasis = Font.subheadline.weight(.medium)

    // MARK: - Controls

    /// "TEMPERATURE", "COLOUR", "GRADIENT", "EFFECT".
    static let sectionLabel = Font.footnote.weight(.semibold)  // 10
    /// The value beside a section label, monospaced so digits do not jitter.
    static let sectionValue = Font.footnote.weight(.medium).monospacedDigit()
    /// Scene, temperature and effect chips.
    static let chipLabel = Font.footnote.weight(.medium)       // 10
    /// Gradient palette captions, the smallest text in the app.
    static let paletteName = Font.caption2                     // 10
    /// Glyphs inside chips and buttons: the scene tick, the room plus, the
    /// banner dismiss.
    static let controlGlyph = Font.caption2.weight(.semibold)  // 9
    static let controlGlyphBold = Font.caption2.weight(.bold)  // 9
    /// The disclosure control on a light row, and the gear.
    static let rowControl = Font.subheadline.weight(.semibold) // 11
    static let toolbarGlyph = Font.callout.weight(.medium)     // 12

    // MARK: - Messages

    static let messageTitle = Font.callout.weight(.medium)     // 12
    static let messageBody = Font.subheadline                  // 11
    static let messageGlyph = Font.title                       // 22
    static let noticeGlyph = Font.title2                       // 20
    static let noticeBody = Font.callout                       // 12
    /// The trademark disclaimer in the gear menu.
    static let finePrint = Font.footnote                       // 10
}

extension View {
    /// Caps how far text may grow.
    ///
    /// A menu-bar popover cannot get wider, and several names are already limited to
    /// one line, so unbounded growth would clip rather than help. Accessibility sizes
    /// are still honoured up to a point where the layout stays legible.
    func dynamicTypeClamped() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// Motion that yields to the accessibility setting.
///
/// Reduce Motion is a request, not a preference to weigh: someone who turns it on
/// may be made unwell by animation. Reading the environment at each call site meant
/// every new animation had to remember to ask, and most did not — so the decision
/// lives here instead.
extension View {
    /// An animation that becomes no animation when Reduce Motion is on.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducedMotion(animation: animation, value: value))
    }
}

private struct ReducedMotion<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
