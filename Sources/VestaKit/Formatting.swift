// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Locale-correct formatting for the numbers Vesta puts on screen.
///
/// String interpolation produces en-US regardless of where the user is: `"72%"`
/// rather than `"72 %"`, Western digits in locales that use their own, and a full
/// stop where a comma belongs. None of that is visible while developing in one
/// locale, and all of it is visible to everyone else.
/// The formatters are `nonisolated(unsafe)`: Foundation's formatters are not
/// Sendable, but these are configured once at initialisation and only ever read
/// afterwards, and every call site is on the main actor.
public enum Formatting {

    nonisolated(unsafe) private static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// A 0–1 brightness as a percentage.
    public static func percentage(_ fraction: Double) -> String {
        percent.string(from: NSNumber(value: fraction)) ?? "\(Int(fraction * 100))%"
    }

    nonisolated(unsafe) private static let measurement: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit    // never convert kelvin to °C
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    /// A colour temperature, in kelvin.
    ///
    /// `unitOptions = .providedUnit` matters: without it the formatter helpfully
    /// converts to degrees Celsius in most of the world, and 2700 K becomes 2427 °C.
    public static func kelvin(_ value: Int) -> String {
        measurement.string(from: Measurement(value: Double(value), unit: UnitTemperature.kelvin))
    }
}
