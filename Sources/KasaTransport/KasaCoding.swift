// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit
import KasaKit

/// All dictionaries stay in the transport. Only bounded, typed values reach the UI.
enum KasaCoding {
    static let limit = 262_144

    static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= limit,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KasaError.invalidResponse
        }
        return object
    }

    static func text(_ value: Any?, fallback: String = "", limit: Int = 100) -> String {
        guard let value = value as? String else { return fallback }
        return String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
    }

    static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else { return nil }
        return Int(value)
    }

    static func identity(_ info: [String: Any], host: String) -> String {
        let raw = text(info["mac"] ?? info["mic_mac"] ?? info["deviceId"] ?? info["device_id"], fallback: host, limit: 160)
        let normalized = raw.lowercased().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func discovery(_ data: Data, host: String, port: UInt16) throws -> KasaDevice {
        if port == 9999 {
            let root = try object(KasaCrypto.xorDecode(data))
            guard let system = root["system"] as? [String: Any],
                  let info = system["get_sysinfo"] as? [String: Any] else { throw KasaError.invalidResponse }
            let base = KasaDevice(id: identity(info, host: host), host: host, name: "Kasa device", model: "")
            guard let device = try devices(root, base: base).first else { throw KasaError.invalidResponse }
            return device
        }
        guard data.count > 16 else { throw KasaError.invalidResponse }
        let root = try object(Data(data.dropFirst(16)))
        guard let info = root["result"] as? [String: Any] else { throw KasaError.invalidResponse }
        let family = text(info["device_type"])
        let scheme = info["mgt_encrypt_schm"] as? [String: Any] ?? [:]
        let encryption = text(scheme["encrypt_type"])
        let isSupported = family.hasPrefix("IOT.") && encryption == "KLAP"
            && (scheme["is_support_https"] as? Bool != true)
            && (integer(scheme["http_port"], in: 1...65535) ?? 80) == 80
        let model = text(info["device_model"], fallback: "Kasa device")
        return KasaDevice(id: identity(info, host: host), host: host,
            name: text(info["alias"], fallback: model), model: model,
            family: family, transport: isSupported ? .klap : .unsupported,
            connection: isSupported ? .signInRequired : .unsupported,
            isBulb: family.contains("BULB"))
    }

    static func devices(_ response: [String: Any], base: KasaDevice) throws -> [KasaDevice] {
        guard let system = response["system"] as? [String: Any],
              let info = system["get_sysinfo"] as? [String: Any] else { throw KasaError.invalidResponse }
        try checkErrors(response)
        var device = base
        device.id = identity(info, host: base.host)
        device.name = text(info["alias"], fallback: base.name)
        device.model = text(info["model"], fallback: base.model)
        device.firmware = text(info["sw_ver"])
        device.hardware = text(info["hw_ver"])
        device.connection = .ready
        device.isBulb = info["light_state"] != nil
        if let light = info["light_state"] as? [String: Any] {
            guard let on = integer(light["on_off"], in: 0...1) else { throw KasaError.invalidResponse }
            device.isOn = on == 1
            let state = device.isOn ? light : (light["dft_on_state"] as? [String: Any] ?? light)
            if integer(info["is_dimmable"], in: 0...1) == 1 {
                device.brightness = integer(state["brightness"], in: 1...100)
            }
            device.supportsColor = integer(info["is_color"], in: 0...1) == 1
            device.supportsTemperature = integer(info["is_variable_color_temp"], in: 0...1) == 1
            device.colorTemperature = integer(state["color_temp"], in: 0...9000)
            device.hue = integer(state["hue"], in: 0...360)
            device.saturation = integer(state["saturation"], in: 0...100)
        } else if let children = info["children"] as? [[String: Any]], !children.isEmpty {
            return try children.prefix(32).map { child in
                var outlet = device
                let childID = text(child["id"], limit: 160)
                guard !childID.isEmpty, let state = integer(child["state"], in: 0...1) else {
                    throw KasaError.invalidResponse
                }
                outlet.id = device.id + ":" + childID
                outlet.childID = childID; outlet.parentID = device.id
                outlet.name = text(child["alias"], fallback: "\(device.name) outlet")
                outlet.isOn = state == 1
                return outlet
            }
        } else {
            guard let on = integer(info["relay_state"], in: 0...1) else { throw KasaError.invalidResponse }
            device.isOn = on == 1
            if info["brightness"] != nil { device.brightness = integer(info["brightness"], in: 1...100) }
        }
        return [device]
    }

    static func checkErrors(_ object: [String: Any], depth: Int = 0) throws {
        guard depth < 32 else { throw KasaError.invalidResponse }
        for (key, value) in object {
            if key == "err_code", let code = integer(value, in: -100_000...100_000), code != 0 {
                throw KasaError.rejected(code)
            }
            if let child = value as? [String: Any] { try checkErrors(child, depth: depth + 1) }
        }
    }

    static func request(_ command: KasaCommand, device: KasaDevice) throws -> Data {
        var object: [String: Any]
        if device.isBulb {
            var state: [String: Any] = ["transition_period": 0]
            switch command {
            case .power(let on): state["on_off"] = on ? 1 : 0; state["ignore_default"] = 0
            case .brightness(let value):
                guard device.brightness != nil, (1...100).contains(value) else { throw KasaError.unsupported }
                state["brightness"] = value
            case .temperature(let value):
                guard device.supportsTemperature, (2500...6500).contains(value) else { throw KasaError.unsupported }
                state["color_temp"] = value
            case .color(let hue, let saturation):
                guard device.supportsColor, (0...360).contains(hue), (0...100).contains(saturation) else { throw KasaError.unsupported }
                state["color_temp"] = 0; state["hue"] = hue; state["saturation"] = saturation
            }
            object = ["smartlife.iot.smartbulb.lightingservice": ["transition_light_state": state]]
        } else {
            switch command {
            case .power(let on): object = ["system": ["set_relay_state": ["state": on ? 1 : 0]]]
            case .brightness(let value):
                guard device.brightness != nil, (1...100).contains(value) else { throw KasaError.unsupported }
                object = ["smartlife.iot.dimmer": ["set_brightness": ["brightness": value]]]
            default: throw KasaError.unsupported
            }
        }
        if let child = device.childID { object["context"] = ["child_ids": [child]] }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
