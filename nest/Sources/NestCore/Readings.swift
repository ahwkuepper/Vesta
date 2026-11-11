import Foundation

public struct Readings: Codable, Sendable {
    public let fetchedAt: Date
    public let thermostats: [Thermostat]

    public struct Thermostat: Codable, Sendable {
        // Routing metadata stays in memory and is excluded from CLI JSON output.
        public var resource: String? = nil
        public var availableModes: [String] = []
        private enum CodingKeys: String, CodingKey {
            case name, connectivity, temperatureCelsius, humidityPercent, mode, hvac, eco
            case heatCelsius, coolCelsius, ecoHeatCelsius, ecoCoolCelsius
        }
        public let name: String
        public let connectivity: String?
        public let temperatureCelsius: Double?
        public let humidityPercent: Double?
        public let mode: String?
        public let hvac: String?
        public let eco: String?
        public let heatCelsius: Double?
        public let coolCelsius: Double?
        public let ecoHeatCelsius: Double?
        public let ecoCoolCelsius: Double?
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> Self {
        guard data.count <= 1_048_576,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReaderError.malformedResponse
        }
        // The API represents an empty device list as {}.
        let devices: [[String: Any]]
        if root["devices"] == nil { devices = [] }
        else if let list = root["devices"] as? [[String: Any]], list.count <= 100 { devices = list }
        else { throw ReaderError.malformedResponse }
        var thermostats: [Thermostat] = []
        for device in devices where device["type"] as? String == "sdm.devices.types.THERMOSTAT" {
            guard let traits = device["traits"] as? [String: Any] else { throw ReaderError.malformedResponse }
            func trait(_ name: String) -> [String: Any] { traits["sdm.devices.traits." + name] as? [String: Any] ?? [:] }
            func number(_ name: String, _ field: String, _ range: ClosedRange<Double>) throws -> Double? {
                guard let value = trait(name)[field] else { return nil }
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, range.contains(n.doubleValue) else { throw ReaderError.malformedResponse }
                return n.doubleValue
            }
            func label(_ name: String, _ field: String) -> String? {
                guard let text = trait(name)[field] as? String else { return nil }
                return Self.safeLabel(text)
            }
            let custom = label("Info", "customName") ?? ""
            let room = (device["parentRelations"] as? [[String: Any]])?.first?["displayName"] as? String
            let name = !custom.isEmpty ? custom : room.map(Self.safeLabel) ?? "Thermostat"
            var thermostat = Thermostat(
                name: name, connectivity: label("Connectivity", "status"),
                temperatureCelsius: try number("Temperature", "ambientTemperatureCelsius", -100...150),
                humidityPercent: try number("Humidity", "ambientHumidityPercent", 0...100),
                mode: label("ThermostatMode", "mode"), hvac: label("ThermostatHvac", "status"),
                eco: label("ThermostatEco", "mode"),
                heatCelsius: try number("ThermostatTemperatureSetpoint", "heatCelsius", -100...150),
                coolCelsius: try number("ThermostatTemperatureSetpoint", "coolCelsius", -100...150),
                ecoHeatCelsius: try number("ThermostatEco", "heatCelsius", -100...150),
                ecoCoolCelsius: try number("ThermostatEco", "coolCelsius", -100...150))
            thermostat.resource = device["name"] as? String
            thermostat.availableModes = (trait("ThermostatMode")["availableModes"] as? [String] ?? [])
                .filter { ["HEAT", "COOL", "HEATCOOL", "OFF"].contains($0) }
            thermostats.append(thermostat)
        }
        return Readings(fetchedAt: fetchedAt, thermostats: thermostats)
    }

    private static func safeLabel(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }).prefix(160))
    }

    public var text: String {
        var lines = ["Fetched from Google: \(fetchedAt.ISO8601Format())"]
        if thermostats.isEmpty { lines.append("No thermostats returned. Check device permissions in Google Nest Partner Connections.") }
        func temperature(_ value: Double?) -> String {
            guard let value else { return "Unavailable" }
            return String(format: "%.1f°F / %.1f°C", value * 9 / 5 + 32, value)
        }
        for t in thermostats {
            lines += ["", t.name, "Connection: \(t.connectivity ?? "Unknown")",
                      "Temperature: \(temperature(t.temperatureCelsius))",
                      "Humidity: \(t.humidityPercent.map { String(format: "%.0f%%", $0) } ?? "Unavailable")",
                      "Mode: \(t.mode ?? "Unknown"); HVAC: \(t.hvac ?? "Unknown"); Eco: \(t.eco ?? "Unknown")"]
            if t.connectivity != "ONLINE" { lines.append("Device is not reported online; values may be stale.") }
            if t.eco == "MANUAL_ECO" {
                lines += ["Eco heating threshold: \(temperature(t.ecoHeatCelsius))",
                          "Eco cooling threshold: \(temperature(t.ecoCoolCelsius))"]
            } else {
                if t.heatCelsius != nil { lines.append("Heating setpoint: \(temperature(t.heatCelsius))") }
                if t.coolCelsius != nil { lines.append("Cooling setpoint: \(temperature(t.coolCelsius))") }
            }
        }
        return lines.joined(separator: "\n")
    }
}
