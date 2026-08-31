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
extension View {

    func chipStyle(isActive: Bool = false) -> some View {
        // A fill, not a ring: `strokeBorder` draws inside the shape, so an outlined
        // chip reads as smaller than its neighbours even though the geometry matches.
        background(
            Capsule().fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        )
        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }

    /// No-op, kept so call sites read the same whether or not grouping applies.
    func chipGroup(spacing: CGFloat = 6) -> some View { self }

    /// One size for every chip. Scenes, temperature presets and effects are one
    /// visual vocabulary and had drifted 1–2pt apart in padding and text size.
    func chipMetrics() -> some View {
        font(.chipLabel)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
    }
}
