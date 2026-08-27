import SwiftUI
import VestaKit

extension Color {
    init(_ rgb: ColorScience.RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

/// A slider whose track previews the result of moving it.
///
/// The stock `Slider` is the right control for an abstract quantity. This app
/// controls something you can look at, so the track shows the actual light: black
/// to the bulb's colour for brightness, and the real Planckian ramp for colour
/// temperature. It also lets you drag from anywhere on the track rather than
/// requiring you to grab a small thumb.
struct GradientSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var gradient: Gradient
    var label: String
    /// Formats the value for VoiceOver and the trailing readout.
    var format: (Double) -> String
    var isEnabled: Bool = true

    @State private var isDragging = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.keyboardActivity) private var keyboard

    /// Drawn only while the keyboard is in use — see `KeyboardActivity`. A ring that
    /// is always on is noise for the pointer users who are most of the audience.
    private var showsFocusRing: Bool { isFocused && keyboard.isActive }

    /// One arrow press. Twenty steps across the range matches what VoiceOver's
    /// adjustable action already uses.
    private var step: Double { (range.upperBound - range.lowerBound) / 20 }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    private func adjust(by delta: Double) -> KeyPress.Result {
        value = (value + delta).clamped(to: range)
        return .handled
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbSize: CGFloat = isDragging ? 23 : 20
            // The handle is a capsule wider than it is tall, so the travel has to be
            // inset by its width — not its height — or it runs past the track ends.
            let thumbWidth = thumbSize * 1.55
            let thumbX = (width - thumbWidth) * fraction + thumbWidth / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 12)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))

                GlassKnob(diameter: thumbSize, isActive: isDragging)
                    .position(x: thumbX, y: geometry.size.height / 2)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            // A stock Slider is Tab-reachable and arrow-operable for free; a custom
            // control gets neither unless it asks. Without this, brightness and
            // colour cannot be set from the keyboard at all.
            .focusable(isEnabled)
            .focused($isFocused)
            // SwiftUI draws its own focus ring on a focusable view, and that one
            // does not fade — it would sit under the custom ring permanently. The
            // ring below replaces it, and is shown only while the keyboard is in use.
            .focusEffectDisabled()
            .overlay(
                Capsule()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .opacity(showsFocusRing ? 1 : 0)
                    .motion(.easeOut(duration: 0.25), value: showsFocusRing)
            )
            .onKeyPress(.leftArrow)  { adjust(by: -step) }
            .onKeyPress(.rightArrow) { adjust(by: step) }
            .onKeyPress(.downArrow)  { adjust(by: -step) }
            .onKeyPress(.upArrow)    { adjust(by: step) }
            .onKeyPress(.home)       { value = range.lowerBound; return .handled }
            .onKeyPress(.end)        { value = range.upperBound; return .handled }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.12)) {
                                isDragging = true
                            }
                        }
                        let f = ((drag.location.x - thumbWidth / 2) / (width - thumbWidth))
                            .clamped(to: 0...1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                            isDragging = false
                        }
                    }
            )
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = (value + step).clamped(to: range)
            case .decrement: value = (value - step).clamped(to: range)
            @unknown default: break
            }
        }
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}

extension Gradient {
    /// Black → the light's own colour, so the track previews the actual result.
    static func brightness(of color: ColorScience.RGB) -> Gradient {
        Gradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.07), Color(color)])
    }

    /// The real Planckian locus across the bulb's supported range, warm on the
    /// left because that is where the low-Kelvin end lives.
    static var colorTemperature: Gradient {
        let stops = stride(from: LightColor.miredRange.upperBound,
                           through: LightColor.miredRange.lowerBound, by: -20)
            .map { Color(ColorScience.rgb(fromMireds: $0)) }
        return Gradient(colors: stops)
    }

    /// Full hue sweep for the colour control.
    static var hue: Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.05)
            .map { Color(hue: $0, saturation: 0.85, brightness: 1.0) })
    }
}
