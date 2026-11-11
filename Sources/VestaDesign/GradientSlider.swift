// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import VestaKit

public extension Color {
    init(_ rgb: ColorScience.RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

/// Native macOS slider behavior and handle, with a track that previews the light.
/// AppKit owns knob drawing, hit testing, tracking, focus and accessibility. In
/// particular, its resting handle and interaction material follow the current OS.
public struct GradientSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var gradient: Gradient
    var label: String
    var format: (Double) -> String
    var isEnabled: Bool = true

    public init(value: Binding<Double>, range: ClosedRange<Double> = 0...1,
                gradient: Gradient, label: String, format: @escaping (Double) -> String,
                isEnabled: Bool = true) {
        self._value = value; self.range = range; self.gradient = gradient
        self.label = label; self.format = format; self.isEnabled = isEnabled
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSSlider {
        let slider = NativeGradientSlider(frame: .zero)
        slider.cell = GradientSliderCell()
        slider.sliderType = .linear
        slider.isVertical = false
        slider.isContinuous = true
        slider.controlSize = .large
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    public func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = min(max(value, range.lowerBound), range.upperBound)
        slider.isEnabled = isEnabled && context.environment.isEnabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(format(slider.doubleValue))
        if let cell = slider.cell as? GradientSliderCell {
            let stops = gradient.stops
            cell.gradient = NSGradient(colors: stops.map { NSColor($0.color) },
                                       atLocations: stops.map(\.location),
                                       colorSpace: .deviceRGB)
        }
        slider.needsDisplay = true
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: max(24, nsView.intrinsicContentSize.height))
    }

    @MainActor
    public final class Coordinator: NSObject {
        var parent: GradientSlider
        init(_ parent: GradientSlider) { self.parent = parent }

        @objc func changed(_ slider: NSSlider) {
            guard slider.isEnabled else { return }
            slider.setAccessibilityValueDescription(parent.format(slider.doubleValue))
            parent.value = slider.doubleValue
        }
    }
}

/// Preserve Vesta's keyboard access even when macOS's optional full keyboard
/// navigation setting is off. AppKit still owns pointer tracking and the knob.
private final class NativeGradientSlider: NSSlider {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let step = (maxValue - minValue) / 20
        switch event.keyCode {
        case 123, 125: doubleValue = max(minValue, doubleValue - step)
        case 124, 126: doubleValue = min(maxValue, doubleValue + step)
        case 115: doubleValue = minValue
        case 119: doubleValue = maxValue
        default:
            super.keyDown(with: event)
            return
        }
        sendAction(action, to: target)
    }
}

/// Only the rail is customized. Do not override knob drawing or geometry: that
/// would replace the system's Liquid Glass slider with another imitation.
private final class GradientSliderCell: NSSliderCell {
    var gradient: NSGradient?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let rail = NSRect(x: rect.minX, y: rect.midY - 4, width: rect.width, height: 8)
        let path = NSBezierPath(roundedRect: rail, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        gradient?.draw(in: path, angle: 0)
    }
}

public extension Gradient {
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
