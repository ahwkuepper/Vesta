// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Conversions between what the bulb speaks and what we can draw on screen.
///
/// These exist so the UI can show a bulb's *actual* colour — a swatch you can
/// compare against the room, and gradient slider tracks that preview the result.
/// A brightness slider that looks like a volume slider throws away the one thing
/// this app has going for it.
public enum ColorScience {

    public struct RGB: Sendable, Equatable {
        public var r: Double, g: Double, b: Double  // 0…1, sRGB
        public init(r: Double, g: Double, b: Double) {
            self.r = r; self.g = g; self.b = b
        }
    }

    // MARK: - Colour temperature

    public static func kelvin(fromMireds mireds: Int) -> Double {
        1_000_000.0 / Double(max(mireds, 1))
    }

    public static func mireds(fromKelvin kelvin: Double) -> Int {
        Int((1_000_000.0 / max(kelvin, 1)).rounded())
            .clamped(to: LightColor.miredRange.lowerBound...LightColor.miredRange.upperBound)
    }

    /// Black-body approximation (Tanner Helland's fit). Accurate enough for a
    /// swatch, and cheap enough to evaluate per-frame across a gradient.
    public static func rgb(fromKelvin kelvin: Double) -> RGB {
        let t = kelvin.clamped(to: 1000...40000) / 100

        let r: Double
        if t <= 66 {
            r = 255
        } else {
            r = (329.698727446 * pow(t - 60, -0.1332047592)).clamped(to: 0...255)
        }

        let g: Double
        if t <= 66 {
            g = (99.4708025861 * log(t) - 161.1195681661).clamped(to: 0...255)
        } else {
            g = (288.1221695283 * pow(t - 60, -0.0755148492)).clamped(to: 0...255)
        }

        let b: Double
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = (138.5177312231 * log(t - 10) - 305.0447927307).clamped(to: 0...255)
        }

        return RGB(r: r / 255, g: g / 255, b: b / 255)
    }

    public static func rgb(fromMireds mireds: Int) -> RGB {
        rgb(fromKelvin: kelvin(fromMireds: mireds))
    }

    // MARK: - CIE xy

    /// CIE 1931 xy → sRGB, using the Wide-RGB-D65 matrix Philips documents for Hue.
    /// `brightness` scales luminance so an almost-off bulb reads as almost-black.
    public static func rgb(fromXY x: Double, _ y: Double, brightness: Double = 1.0) -> RGB {
        guard y > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }

        let Y = brightness.clamped(to: 0...1)
        let X = (Y / y) * x
        let Z = (Y / y) * (1 - x - y)

        var r =  X * 1.656492 - Y * 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
        var b =  X * 0.051713 - Y * 0.121364 + Z * 1.011530

        // Desaturate toward white rather than clipping a channel to zero, which
        // would shift the hue instead of just the intensity.
        let maxC = max(r, g, b)
        if maxC > 1 { r /= maxC; g /= maxC; b /= maxC }

        func gamma(_ c: Double) -> Double {
            let c = c.clamped(to: 0...1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGB(r: gamma(r), g: gamma(g), b: gamma(b))
    }

    /// sRGB → CIE xy, for sending a colour the user picked back to the bulb.
    public static func xy(fromRGB rgb: RGB) -> (x: Double, y: Double) {
        func linear(_ c: Double) -> Double {
            let c = c.clamped(to: 0...1)
            return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)

        let X = r * 0.649926 + g * 0.103455 + b * 0.197109
        let Y = r * 0.234327 + g * 0.743075 + b * 0.022598
        let Z = r * 0.000000 + g * 0.053077 + b * 1.035763

        let sum = X + Y + Z
        guard sum > 0.0001 else { return (0.3127, 0.3290) }  // D65 white
        return (X / sum, Y / sum)
    }

    /// The colour a light is actually emitting, for swatches and row tinting.
    public static func rgb(for state: LightState) -> RGB {
        switch state.color {
        case .temperature(let mireds):
            return rgb(fromMireds: mireds)
        case .xy(let x, let y):
            return rgb(fromXY: x, y, brightness: 1.0)
        }
    }
}
