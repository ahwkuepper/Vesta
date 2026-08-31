// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
// CBUUID is an unaudited Objective-C type and is not Sendable, but these instances
// are immutable constants. @preconcurrency keeps the framework's Sendable gaps from
// becoming errors; nonisolated(unsafe) states the intent on each constant.
@preconcurrency import CoreBluetooth
import VestaKit

/// Wire format for the Hue BLE control service.
///
/// UUIDs and semantics confirmed empirically against two LCB002 bulbs
/// (firmware 1.163.1). All characteristics also support
/// `notify`, which is why this app subscribes rather than polls.
public enum HueProtocol {

    /// Advertised 16-bit service that marks a peripheral as a Hue device.
    nonisolated(unsafe) public static let advertisedService = CBUUID(string: "FE0F")
    nonisolated(unsafe) public static let controlService = CBUUID(string: "932c32bd-0000-47a2-835a-a8d455b859dd")
    nonisolated(unsafe) public static let deviceInfoService = CBUUID(string: "180A")

    nonisolated(unsafe) public static let power = CBUUID(string: "932c32bd-0002-47a2-835a-a8d455b859dd")
    nonisolated(unsafe) public static let brightness = CBUUID(string: "932c32bd-0003-47a2-835a-a8d455b859dd")
    nonisolated(unsafe) public static let temperature = CBUUID(string: "932c32bd-0004-47a2-835a-a8d455b859dd")
    nonisolated(unsafe) public static let color = CBUUID(string: "932c32bd-0005-47a2-835a-a8d455b859dd")

    /// Readable without a bond, so we can name and identify bulbs before pairing.
    nonisolated(unsafe) public static let modelNumber = CBUUID(string: "2A24")
    nonisolated(unsafe) public static let manufacturer = CBUUID(string: "2A29")
    nonisolated(unsafe) public static let firmware = CBUUID(string: "2A28")

    nonisolated(unsafe) public static let controlCharacteristics: [CBUUID] =
        [power, brightness, temperature, color]

    // MARK: - Encoding

    public static func powerPayload(_ on: Bool) -> Data {
        Data([on ? 0x01 : 0x00])
    }

    /// The bulb's brightness range is 1…254; 0 is not "off", it is invalid.
    public static func brightnessPayload(_ brightness: Double) -> Data {
        let scaled = 1 + brightness.clamped(to: 0...1) * 253
        return Data([UInt8(scaled.rounded())])
    }

    /// Mireds, uint16 little-endian.
    public static func temperaturePayload(mireds: Int) -> Data {
        let m = UInt16(mireds.clamped(to: LightColor.miredRange.lowerBound...LightColor.miredRange.upperBound))
        return Data([UInt8(m & 0xFF), UInt8(m >> 8)])
    }

    /// CIE xy as two uint16 little-endian values scaled across the 0…1 range.
    public static func colorPayload(x: Double, y: Double) -> Data {
        let xi = UInt16((x.clamped(to: 0...1) * 65535).rounded())
        let yi = UInt16((y.clamped(to: 0...1) * 65535).rounded())
        return Data([UInt8(xi & 0xFF), UInt8(xi >> 8), UInt8(yi & 0xFF), UInt8(yi >> 8)])
    }

    // MARK: - Decoding (for `notify` updates)

    public static func decodePower(_ data: Data) -> Bool? {
        data.first.map { $0 != 0 }
    }

    public static func decodeBrightness(_ data: Data) -> Double? {
        guard let raw = data.first else { return nil }
        return (Double(raw) - 1) / 253
    }

    public static func decodeTemperature(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        return Int(data[0]) | (Int(data[1]) << 8)
    }

    public static func decodeColor(_ data: Data) -> (x: Double, y: Double)? {
        guard data.count >= 4 else { return nil }
        let xi = Int(data[0]) | (Int(data[1]) << 8)
        let yi = Int(data[2]) | (Int(data[3]) << 8)
        return (Double(xi) / 65535, Double(yi) / 65535)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}
