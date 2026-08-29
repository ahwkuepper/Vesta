// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Ready-made gradients for fixtures like the Play lamps.
///
/// Hue's own preset looks only exist on the bridge once they have been saved from
/// the Hue app, so there is no library to read. These are Vesta's, chosen so the
/// first one does the most useful thing: make a gradient lamp behave like an
/// ordinary warm lamp lighting the room.
public struct GradientPalette: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let gradient: LightGradient

    public init(name: String, gradient: LightGradient) {
        self.name = name
        self.gradient = gradient
    }

    private static func xy(_ pairs: [(Double, Double)]) -> LightGradient {
        LightGradient(points: pairs.map { .xy(x: $0.0, y: $0.1) })
    }

    public static let sunset = GradientPalette(name: "Sunset", gradient: xy([
        (0.604, 0.371), (0.556, 0.383), (0.489, 0.360), (0.417, 0.301), (0.352, 0.234),
    ]))

    public static let ocean = GradientPalette(name: "Ocean", gradient: xy([
        (0.216, 0.386), (0.190, 0.335), (0.171, 0.283), (0.163, 0.232), (0.158, 0.188),
    ]))

    public static let forest = GradientPalette(name: "Forest", gradient: xy([
        (0.328, 0.512), (0.360, 0.489), (0.395, 0.462), (0.432, 0.436), (0.470, 0.412),
    ]))

    /// Only genuinely multi-colour looks belong here. Uniform "gradients" — five
    /// identical points — are flat colour wearing a gradient's clothes, and are
    /// indistinguishable from simply setting a colour temperature, which the bridge
    /// honours by clearing the gradient points anyway. Those live in
    /// `TemperaturePreset` instead, next to the control that actually governs them.
    public static let all: [GradientPalette] = [sunset, ocean, forest]
}

/// One-tap colour temperatures.
///
/// These are positions on the temperature slider, not gradients. On a fixture that
/// supports gradients, setting a colour temperature also clears the gradient, so
/// these double as the way back to ordinary flat room lighting.
public struct TemperaturePreset: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let mireds: Int

    public init(name: String, mireds: Int) {
        self.name = name
        self.mireds = mireds
    }

    public var kelvin: Int { Int(ColorScience.kelvin(fromMireds: mireds)) }

    public static let all: [TemperaturePreset] = [
        TemperaturePreset(name: "Candle", mireds: 500),   // ~2000 K
        TemperaturePreset(name: "Warm", mireds: 370),     // ~2700 K
        TemperaturePreset(name: "Reading", mireds: 303),  // ~3300 K
        TemperaturePreset(name: "Cool", mireds: 200),     // ~5000 K
    ]
}
