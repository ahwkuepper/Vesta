import SwiftUI

/// Whether Liquid Glass is drawn.
///
/// `glassEffect` nested inside the popover's scroll view hangs the offscreen
/// snapshot renderer indefinitely — verified by bisection, and it renders correctly
/// in a simple hosted view, so it is specific to that nesting. The live app is
/// unaffected; only documentation rendering is, so snapshots draw the fallback.
///
/// The check is behind `AnyView` deliberately. Gating with `@Environment` was not
/// enough: the glass branch still lands in the view tree's type, and merely being
/// there is sufficient to hang the render.
enum GlassSettings {
    nonisolated(unsafe) static var isEnabled = true
}

/// The slider handle.
///
/// On macOS 26 and later this is the system's own Liquid Glass — `glassEffect` with
/// `.clear.interactive()`, so it refracts the track beneath it, responds to press,
/// and picks up whatever the platform does next without this file being touched.
/// Imitating a material with gradients means reimplementing it every time Apple
/// refines it; using the framework means inheriting those refinements.
///
/// The hand-drawn capsule below is the fallback for the macOS 14 build variant,
/// where Liquid Glass does not exist. It approximates the same cues — a translucent
/// body so the track shows through, a Fresnel rim because glass is brightest
/// edge-on, one specular highlight, a contact shadow — but it is an approximation,
/// and is used only where the real thing is unavailable.
///
/// Either way the handle is a capsule elongated along the axis it travels, matching
/// the platform's sliders: a circle reads as a bead resting on the track, a capsule
/// reads as a handle belonging to it.
struct GlassKnob: View {
    /// Height of the handle. Width is derived — see `width`.
    var diameter: CGFloat
    var isActive: Bool

    private var width: CGFloat { diameter * 1.55 }
    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        #if LUMO_GLASS
        if #available(macOS 26.0, *), GlassSettings.isEnabled {
            AnyView(
                Color.clear
                    .frame(width: width, height: diameter)
                    // .clear, not .regular: regular is the frosted variant and hides
                    // the track it sits on, which is the opposite of what a handle
                    // over a colour gradient should do.
                    //
                    // .interactive() takes isEnabled, so passing the drag state made
                    // the handle interactive only while already being dragged — the
                    // press response was missing exactly when it should appear.
                    .glassEffect(.clear.interactive(), in: shape)
            )
        } else {
            AnyView(fallback)
        }
        #else
        // Built against an SDK without Liquid Glass; only the fallback exists.
        AnyView(fallback)
        #endif
    }

    /// Approximation for the macOS 14 build, where `glassEffect` does not exist.
    private var fallback: some View {
        ZStack {
            shape
                .fill(.white.opacity(0.32))

            shape
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.75), .white.opacity(0.18), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.95), .white.opacity(0.25),
                                 .white.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: max(0.75, diameter * 0.055))

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), .white.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.22))
                .frame(width: width * 0.40, height: diameter * 0.32)
                .offset(x: -width * 0.14, y: -diameter * 0.20)
                .blur(radius: diameter * 0.03)
        }
        .frame(width: width, height: diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(isActive ? 0.34 : 0.24),
                radius: isActive ? 3.5 : 2,
                y: isActive ? 1.5 : 1)
        .overlay(shape.strokeBorder(.black.opacity(0.10), lineWidth: 0.5))
    }
}
