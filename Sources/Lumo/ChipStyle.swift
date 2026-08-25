import SwiftUI

/// Chip styling shared by scenes, temperature presets and effects.
///
/// Deliberately neutral, and deliberately not Liquid Glass. Two attempts at colour
/// here both failed, in instructive ways:
///
///  - Tinting by a hash of the chip's *name* gave stable, distinguishable colours
///    that meant nothing. Harmless as an arbitrary marker; misleading the moment it
///    looked like a statement about the light.
///  - Tinting by the colour the scene or preset actually produces was truthful and
///    still worse. Most domestic lighting sits between 2000 K and 3300 K, so nearly
///    every chip came out the same orange and stopped being distinguishable, while a
///    5000 K chip went near-white and its white label became unreadable.
///
/// The label already says what the chip does. Colour was decoration competing with
/// it, and the failure mode of decoration on a control is illegibility.
///
/// Selection is shown by filling the capsule with the accent colour, plus a tick.
/// That survives any colour scheme and any appearance, and keeps every chip visually
/// the same size — an outline would inset the selected one and make it look smaller.
extension View {

    func chipStyle(tint: Color? = nil, isActive: Bool = false) -> some View {
        // Selection is a fill, not a ring. `strokeBorder` draws inside the shape, so
        // an outlined chip has its coloured area inset by the line width and reads as
        // physically smaller than its neighbours — the geometry is identical, the
        // perception is not. Filling the whole capsule keeps every chip the same size
        // and makes the selected one unmistakable.
        background(
            Capsule().fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        )
        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }

    /// No-op. Kept so call sites read the same whether or not grouping applies; the
    /// glass container it used to create is gone with the glass chips.
    func chipGroup(spacing: CGFloat = 6) -> some View { self }
}
