import SwiftUI

/// Whether Liquid Glass is drawn.
///
/// `glassEffect` produces nothing when a view is drawn in-process, because the
/// window server composites it. The snapshot renderer sets this false when it
/// cannot capture through the compositor; otherwise the handle renders as a hole.
///
/// Gating happens through `AnyView` rather than `@Environment` so the glass branch
/// leaves the view tree entirely.
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

    @Environment(\.colorSchemeContrast) private var contrast

    private var width: CGFloat { diameter * 1.55 }
    private var shape: Capsule { Capsule(style: .continuous) }

    /// A rim and a contact shadow, drawn regardless of what is behind.
    ///
    /// Clear glass defines its edge by refracting whatever it sits on, which works
    /// until it sits on something its own colour. These tracks are deliberately
    /// tinted the colour the light is emitting, so a warm handle over a warm track
    /// had nothing to separate it and read as a smudge — the one place the material
    /// is load-bearing was the one place it disappeared.
    ///
    /// The rim carries dark appearances and the shadow carries light ones, so
    /// between them the edge survives any hue. This is edge definition, not a
    /// reimplementation of the material: the glass still does the refraction, the
    /// press response and whatever Apple does to it next.
    /// The rim is a gradient rather than a uniform ring.
    ///
    /// A ring of even brightness all the way round is what a drawing of glass looks
    /// like; real glass catches light on one edge and goes almost dark on the
    /// opposite one. Most of the separation comes from the contact shadow, which is
    /// quieter than a bright outline and does not compete with the track.
    private var rimGradient: LinearGradient {
        let top = contrast == .increased ? 0.95 : 0.42
        let bottom = contrast == .increased ? 0.55 : 0.06
        return LinearGradient(colors: [.white.opacity(top), .white.opacity(bottom)],
                              startPoint: .top, endPoint: .bottom)
    }

    private var rimWidth: CGFloat {
        contrast == .increased ? max(1.5, diameter * 0.075) : max(0.5, diameter * 0.035)
    }

    var body: some View {
        #if VESTA_GLASS
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
                    .overlay(shape.strokeBorder(rimGradient, lineWidth: rimWidth))
                    // Carries most of the separation now that the rim is quiet:
                    // a soft shadow reads as depth, a bright outline reads as ink.
                    .shadow(color: .black.opacity(isActive ? 0.42 : 0.32),
                            radius: isActive ? 4 : 2.5,
                            y: isActive ? 2 : 1.5)
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
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.9 : 0),
                                    lineWidth: contrast == .increased ? rimWidth : 0))
    }
}
