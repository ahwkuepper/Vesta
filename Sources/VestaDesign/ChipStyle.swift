// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Chip styling shared by scenes, temperature presets and effects.
///
/// Neutral by design. Tinting a chip with the colour its scene or preset produces
/// is truthful but unusable: most domestic lighting falls between 2000 K and 3300 K,
/// so the chips converge on one orange, and a 5000 K chip goes near-white and loses
/// its label. The label already says what the chip does.
///
/// Selection is a filled capsule plus a tick, which survives any appearance.
public extension View {

    func chipStyle(isActive: Bool = false) -> some View {
        modifier(ChipSurface(isActive: isActive))
    }

    @ViewBuilder
    func chipGroup(spacing: CGFloat = 6) -> some View {
        #if VESTA_GLASS
        if #available(macOS 26.0, *), GlassSettings.isEnabled {
            GlassEffectContainer(spacing: spacing) { self }
        } else { self }
        #else
        self
        #endif
    }

    /// One size for every chip. Scenes, temperature presets and effects are one
    /// visual vocabulary and had drifted 1–2pt apart in padding and text size.
    func chipMetrics() -> some View {
        font(.chipLabel)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
    }
}

private struct ChipSurface: ViewModifier {
    let isActive: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                Capsule().strokeBorder(isActive ? Color.clear : Color.primary.opacity(
                    contrast == .increased ? 0.45 : (isHovered ? 0.18 : 0.08)), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .brightness(isHovered && isEnabled ? 0.035 : 0)
            .onHover { isHovered = $0 }
            .motion(.easeOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        #if VESTA_GLASS
        if #available(macOS 26.0, *), GlassSettings.isEnabled, !reduceTransparency {
            content
                .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
                .glassEffect(.regular.tint(isActive ? Color.accentColor : nil).interactive(), in: Capsule())
        } else { fallback(content) }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
            .background {
                if isActive {
                    Capsule().fill(Color.accentColor.gradient)
                } else if reduceTransparency {
                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    Capsule().fill(.primary.opacity(0.065))
                }
            }
    }
}
