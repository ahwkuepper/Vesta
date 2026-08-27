import SwiftUI
import VestaKit

/// One bulb. Collapsed it shows identity, state and brightness — the things you
/// want in one glance. Colour temperature and hue live behind a disclosure, per
/// the HI review: putting every control on every row makes the common action
/// (turn it down a bit) slower, not faster.
struct LightRow: View {
    let light: Light
    @Bindable var store: LightStore
    @Binding var expansion: Expansion
    /// The room this row belongs to, or nil when the light has no room.
    var roomID: Room.ID?

    /// The hue the user last chose, held so the handle does not teleport across the
    /// wrap point. See `displayedHue`.
    @State private var hueOverride: Double?

    private var isExpanded: Bool { expansion.isExpanded(light.id) }
    private var swatch: ColorScience.RGB { ColorScience.rgb(for: light.state) }
    private var isCommandable: Bool { light.connection.isCommandable }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isCommandable {
                brightnessControl
                if isExpanded { colorControls }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            }
        }
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            swatchView

            VStack(alignment: .leading, spacing: 1) {
                Text(light.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                statusLine
            }

            Spacer(minLength: 6)

            if isCommandable {
                Button {
                    expansion.toggle(light.id, in: roomID)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide colour controls" : "Show colour controls")
                .accessibilityLabel(isExpanded ? "Hide colour controls for \(light.name)"
                                               : "Show colour controls for \(light.name)")

                Toggle("", isOn: Binding(
                    get: { light.state.isOn },
                    set: { store.setPower($0, for: light.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("\(light.name) power")
            }
        }
    }

    /// Shows the colour the bulb is actually emitting, so the popover reads as a
    /// picture of the room rather than a list of names.
    private var swatchView: some View {
        ZStack {
            Circle()
                .fill(light.state.isOn && isCommandable
                      ? Color(swatch)
                      : Color.secondary.opacity(0.22))
                .frame(width: 22, height: 22)
                // A lit bulb glows. Cheap, and it makes on/off readable peripherally.
                .shadow(color: light.state.isOn && isCommandable
                        ? Color(swatch).opacity(0.55) : .clear,
                        radius: 6)

            if !isCommandable {
                Image(systemName: light.connection == .needsPairing
                      ? "lock.fill" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.25), value: light.state)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch light.connection {
        case .ready:
            Text(light.state.isOn ? Formatting.percentage(light.state.brightness) : "Off")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .needsPairing:
            // An unpaired bulb is not an off bulb. Greying both out would be a lie.
            Text("Not paired")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
        case .unreachable:
            Text("Unreachable")
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.85))
        case .connecting, .discovered:
            Text(light.connection.shortLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var brightnessControl: some View {
        GradientSlider(
            value: Binding(
                get: { light.state.brightness },
                set: { store.setBrightness($0, for: light.id) }
            ),
            gradient: .brightness(of: swatch),
            label: "\(light.name) brightness",
            format: { Formatting.percentage($0) },
            isEnabled: light.state.isOn
        )
    }

    @ViewBuilder
    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)

            labelled("Temperature", value: temperatureReadout) {
                GradientSlider(
                    value: Binding(
                        get: { temperatureMireds },
                        set: { store.setColor(.temperature(mireds: Int($0)), for: light.id) }
                    ),
                    // Reversed so warm sits on the left: mireds run backwards
                    // against how people think about a warm-to-cool ramp.
                    range: Double(LightColor.miredRange.lowerBound)...Double(LightColor.miredRange.upperBound),
                    gradient: Gradient(colors: Gradient.colorTemperature.stops.map(\.color).reversed()),
                    label: "\(light.name) colour temperature",
                    format: { Formatting.kelvin(Int(ColorScience.kelvin(fromMireds: Int($0)))) },
                    isEnabled: light.state.isOn
                )
            }

            temperaturePresets

            if light.capabilities.supportsGradient { gradientPalettes }
            if !light.capabilities.effects.isEmpty { effectPicker }

            labelled("Colour", value: "\(Int(displayedHue * 360))°") {
                GradientSlider(
                    value: Binding(
                        get: { displayedHue },
                        set: { hue in
                            hueOverride = hue
                            let rgb = NSColor(hue: hue, saturation: 0.9, brightness: 1, alpha: 1)
                            let xy = ColorScience.xy(fromRGB: .init(
                                r: Double(rgb.redComponent),
                                g: Double(rgb.greenComponent),
                                b: Double(rgb.blueComponent)))
                            store.setColor(.xy(x: xy.x, y: xy.y), for: light.id)
                        }
                    ),
                    gradient: .hue,
                    label: "\(light.name) colour",
                    format: { "hue \(Int($0 * 360)) degrees" },
                    isEnabled: light.state.isOn
                )
            }
        }
        // Reveal in place. A .move(edge: .top) transition made the controls fly in
        // from above the row and out through the top again — which reads as a
        // glitch, not a disclosure.
        //
        // Asymmetric on purpose: closing is faster than opening. A symmetric fade
        // left a ghost of the panel hanging over the row it had already vacated.
        // Closing is instant. Any removal fade, however short, leaves a ghost of the
        // panel over the row it has already vacated — the height collapses faster
        // than the pixels do.
        .transition(.asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.16)),
            removal: .identity))
    }

    /// True when the light is already sitting on this preset.
    ///
    /// Answers "is my current temperature exactly one of the presets?" — otherwise
    /// coming back to lights left at some past setting tells you nothing about how
    /// they got there. A few mireds of tolerance, since the bridge rounds.
    private func matches(_ preset: TemperaturePreset) -> Bool {
        guard case .temperature(let mireds) = light.state.color, light.state.isOn else {
            return false
        }
        return abs(mireds - preset.mireds) <= 3
    }

    /// One-tap positions on the temperature slider above. These are flat colours,
    /// not gradients — and on a gradient fixture, writing a colour temperature is
    /// what clears the gradient, so they are also the route back to plain light.
    private var temperaturePresets: some View {
        HStack(spacing: 5) {
            ForEach(TemperaturePreset.all) { preset in
                Button {
                    store.setColor(.temperature(mireds: preset.mireds), for: light.id)
                } label: {
                    Text(preset.name)
                        .chipMetrics()
                        .chipStyle(isActive: matches(preset))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(preset.name) — \(Formatting.kelvin(preset.kelvin))")
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(matches(preset) ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .chipGroup(spacing: 5)
        .opacity(light.state.isOn ? 1 : 0.35)
        .disabled(!light.state.isOn)
    }

    /// Genuine multi-colour gradients only, and no "None" chip.
    ///
    /// There is nothing for it to rescue: writing any flat colour clears the
    /// gradient, verified against a Play lamp — a gradient reads back as 5 points,
    /// and after either an xy colour write or a colour-temperature write it reads
    /// back as 0. So the temperature presets and the colour slider are already the
    /// ways out, and each lands somewhere deliberate, whereas "None" re-applied
    /// whichever colour the gradient's first point happened to be.
    ///
    /// Picking five coordinated colours by hand in a menu-bar popover would be a
    /// worse experience than choosing a look, hence palettes rather than wells.
    private var gradientPalettes: some View {
        labelled("Gradient") {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(GradientPalette.all) { palette in
                        Button {
                            store.setGradient(palette.gradient, for: light.id)
                        } label: {
                            VStack(spacing: 3) {
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: palette.gradient.points.map {
                                            Color(ColorScience.rgb(for: LightState(
                                                isOn: true, brightness: 1, color: $0)))
                                        },
                                        startPoint: .leading, endPoint: .trailing))
                                    .frame(width: 46, height: 12)
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                                Text(palette.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Set \(light.name) to \(palette.name)")
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
        }
    }

    /// Hue's built-in effects, read from the fixture rather than hard-coded — the
    /// bridge reports exactly which ones this lamp supports.
    private var effectPicker: some View {
        labelled("Effect") {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    Button("None") { store.setEffect(nil, for: light.id) }
                        .buttonStyle(.plain)
                        .chipMetrics()
                        .chipStyle(isActive: light.state.effect == nil)
                        .accessibilityLabel("No effect")
                        .accessibilityAddTraits(
                            light.state.effect == nil ? [.isButton, .isSelected] : .isButton)

                    ForEach(light.capabilities.effects, id: \.self) { effect in
                        Button(effect.capitalized) { store.setEffect(effect, for: light.id) }
                            .buttonStyle(.plain)
                            .chipMetrics()
                            .chipStyle(isActive: light.state.effect == effect)
                            .accessibilityLabel(effect.capitalized)
                            .accessibilityAddTraits(
                                light.state.effect == effect ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 1)
                    }
            .scrollIndicators(.never)
        }
    }

    private func labelled<Content: View>(_ title: String, value: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                if let value {
                    Text(value)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            content()
        }
    }

    /// Where the temperature slider currently sits. A light in colour mode has no
    /// colour temperature, but the slider still has a position — the readout has to
    /// agree with the thumb or it is worse than showing nothing.
    private var temperatureMireds: Double {
        if case .temperature(let m) = light.state.color { return Double(m) }
        return 366
    }

    /// Rounded to the nearest 50 K: the underlying mired steps are uneven, and a
    /// readout that jitters between 2703 and 2717 while dragging is unreadable.
    private var temperatureReadout: String {
        let kelvin = ColorScience.kelvin(fromMireds: Int(temperatureMireds))
        return Formatting.kelvin(Int((kelvin / 50).rounded() * 50))
    }

    /// Approximate inverse of the hue slider, so the thumb lands near where the
    /// bulb's current colour sits rather than snapping to zero.
    private func hueFromXY(x: Double, y: Double) -> Double {
        let rgb = ColorScience.rgb(fromXY: x, y, brightness: 1)
        let color = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        return Double(color.usingColorSpace(.deviceRGB)?.hueComponent ?? 0)
    }

    /// The hue the slider should show.
    ///
    /// Hue is a circle and the slider is a line, so red exists at both ends and
    /// converting the light's colour back into a position is ambiguous there. A
    /// threshold cannot fix that: collapsing the top of the range onto zero stops red
    /// jumping right but sends deep magenta jumping left instead — the same defect
    /// mirrored.
    ///
    /// So the position the user set wins. It is kept until the light's colour stops
    /// agreeing with it, which happens when something else changes the light — a
    /// scene, the Hue app, a switch — and at that point the light's own colour is
    /// what should be shown.
    private var displayedHue: Double {
        if let chosen = hueOverride, colourAgrees(with: chosen) { return chosen }
        if case .xy(let x, let y) = light.state.color { return hueFromXY(x: x, y: y) }
        return 0
    }

    /// Whether the light is still showing the hue the slider last sent.
    ///
    /// Compared in hue space, circularly. Comparing xy coordinates instead looked
    /// reasonable and drifted: the bulb clamps a requested colour into its own gamut,
    /// so the xy that comes back is a little way from the one sent, and pure red — at
    /// the very edge of the gamut — moves furthest. That failed the match, the slider
    /// fell back to the light's reported colour, and the handle crept sideways a
    /// second after being released.
    ///
    /// Hue survives gamut clamping much better, and the circular distance also
    /// closes the wrap: an override of 0.0 against a reading of 0.997 is a difference
    /// of 0.003, not 0.997.
    private func colourAgrees(with hue: Double) -> Bool {
        guard case .xy(let x, let y) = light.state.color else { return false }
        let reported = hueFromXY(x: x, y: y)
        let direct = abs(reported - hue)
        return min(direct, 1 - direct) < 0.06
    }
}
