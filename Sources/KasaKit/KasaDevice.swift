// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum KasaConnection: String, Codable, Sendable {
    case ready, signInRequired, offline, unsupported
}

public enum KasaProtocol: String, Codable, Sendable {
    case xor, klap, unsupported
}

public struct KasaDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var name: String
    public var model: String
    public var family: String
    public var transport: KasaProtocol
    public var connection: KasaConnection
    public var isBulb: Bool
    public var isOn: Bool
    public var brightness: Int?
    public var colorTemperature: Int?
    public var hue: Int?
    public var saturation: Int?
    public var supportsColor: Bool
    public var supportsTemperature: Bool
    public var firmware: String
    public var hardware: String
    public var childID: String?
    public var parentID: String?

    public init(id: String, host: String, name: String, model: String,
                family: String = "IOT.SMARTPLUGSWITCH", transport: KasaProtocol = .xor,
                connection: KasaConnection = .ready, isBulb: Bool = false, isOn: Bool = false,
                brightness: Int? = nil, colorTemperature: Int? = nil, hue: Int? = nil,
                saturation: Int? = nil, supportsColor: Bool = false,
                supportsTemperature: Bool = false, firmware: String = "", hardware: String = "",
                childID: String? = nil, parentID: String? = nil) {
        self.id = id; self.host = host; self.name = name; self.model = model
        self.family = family; self.transport = transport; self.connection = connection
        self.isBulb = isBulb; self.isOn = isOn; self.brightness = brightness
        self.colorTemperature = colorTemperature; self.hue = hue; self.saturation = saturation
        self.supportsColor = supportsColor; self.supportsTemperature = supportsTemperature
        self.firmware = firmware; self.hardware = hardware
        self.childID = childID; self.parentID = parentID
    }

    public var canControl: Bool { connection == .ready }
    public var status: String {
        switch connection {
        case .signInRequired: "Sign in to connect"
        case .offline: "Unavailable"
        case .unsupported: "Not supported yet"
        case .ready: isOn ? brightness.map { "\($0)%" } ?? "On" : "Off"
        }
    }
}

public enum KasaCommand: Sendable, Equatable {
    case power(Bool)
    case brightness(Int)
    case temperature(Int)
    case color(hue: Int, saturation: Int)
}

public enum KasaError: Error, LocalizedError, Equatable, Sendable {
    case localNetwork, unavailable, invalidResponse, authentication, unsupported
    case rejected(Int), keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .localNetwork: "Connect to your home Wi-Fi and allow Local Network access in System Settings."
        case .unavailable: "The device didn’t respond. Check its power and Wi-Fi connection."
        case .invalidResponse: "The device returned an unreadable response. Try refreshing."
        case .authentication: "The device needs your Kasa account. Check your email and password, and Third-Party Compatibility in the Kasa app."
        case .unsupported: "This device’s connection protocol isn’t supported yet."
        case .rejected: "The device couldn’t apply that change. Refresh and try again."
        case .keychain(let code): code == -25320
            ? "Wake and unlock this Mac, then refresh to allow access to your saved Kasa sign-in."
            : "Your Kasa sign-in couldn’t be accessed in Keychain (\(code))."
        }
    }
}
