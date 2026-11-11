import Foundation

public enum NestCommand: Sendable, Equatable {
    case heat(Double), cool(Double), range(heat: Double, cool: Double), mode(String), eco(Bool)

    public func body(for thermostat: Readings.Thermostat) throws -> Data {
        guard thermostat.connectivity == "ONLINE" else { throw ReaderError.network }
        var name: String
        var params: [String: Any]
        func temperature(_ value: Double) throws {
            guard value.isFinite, (10...32).contains(value), thermostat.eco == "OFF" else {
                throw ReaderError.invalidCommand
            }
        }
        switch self {
        case .heat(let value):
            try temperature(value)
            guard thermostat.mode == "HEAT" else { throw ReaderError.invalidCommand }
            name = "ThermostatTemperatureSetpoint.SetHeat"; params = ["heatCelsius": value]
        case .cool(let value):
            try temperature(value)
            guard thermostat.mode == "COOL" else { throw ReaderError.invalidCommand }
            name = "ThermostatTemperatureSetpoint.SetCool"; params = ["coolCelsius": value]
        case .range(let heat, let cool):
            try temperature(heat); try temperature(cool)
            guard thermostat.mode == "HEATCOOL", cool - heat >= 0.5 else { throw ReaderError.invalidCommand }
            name = "ThermostatTemperatureSetpoint.SetRange"; params = ["heatCelsius": heat, "coolCelsius": cool]
        case .mode(let value):
            guard thermostat.availableModes.contains(value) else { throw ReaderError.invalidCommand }
            name = "ThermostatMode.SetMode"; params = ["mode": value]
        case .eco(let enabled):
            guard thermostat.mode != "OFF", thermostat.eco != nil else { throw ReaderError.invalidCommand }
            name = "ThermostatEco.SetMode"; params = ["mode": enabled ? "MANUAL_ECO" : "OFF"]
        }
        return try JSONSerialization.data(withJSONObject: ["command": "sdm.devices.commands." + name, "params": params])
    }

    public static func validResource(_ value: String, project: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return parts.count == 4 && parts[0] == "enterprises" && parts[1] == project
            && UUID(uuidString: project) != nil && parts[2] == "devices"
            && (1...1024).contains(parts[3].count) && parts[3].unicodeScalars.allSatisfy { safe.contains($0) }
    }

    public static func permits(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == "smartdevicemanagement.googleapis.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              request.httpMethod == "POST", url.path.hasPrefix("/v1/"), url.path.hasSuffix(":executeCommand"),
              let data = request.httpBody, data.count < 4096,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = object["command"] as? String,
              ["ThermostatTemperatureSetpoint.SetHeat", "ThermostatTemperatureSetpoint.SetCool",
               "ThermostatTemperatureSetpoint.SetRange", "ThermostatMode.SetMode", "ThermostatEco.SetMode"]
                .map({ "sdm.devices.commands." + $0 }).contains(command) else { return false }
        let resource = String(url.path.dropFirst(4).dropLast(15))
        let parts = resource.split(separator: "/")
        return parts.count == 4 && validResource(resource, project: String(parts[1]))
    }
}
