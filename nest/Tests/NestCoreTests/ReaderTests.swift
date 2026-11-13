import Foundation
import Testing
@testable import NestCore

private let project = "11111111-2222-3333-4444-555555555555"
private let moment = Date(timeIntervalSince1970: 1_800_000_000)
private func config() -> Credentials {
    Credentials(projectID: project, clientID: "synthetic.apps.googleusercontent.com", clientSecret: "test-secret+&=")
}

private final class Store: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    private var failWrites = false
    init(_ value: Credentials? = nil) { self.value = value }
    func load() throws -> Credentials? { lock.withLock { value } }
    func save(_ new: Credentials) throws {
        try lock.withLock {
            if failWrites { throw ReaderError.keychain(-1) }
            value = new
        }
    }
    func delete() throws { lock.withLock { value = nil } }
    func rejectWrites() { lock.withLock { failWrites = true } }
}

private actor HTTP: HTTPClient {
    var requests: [URLRequest] = []
    var responses: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ReaderError.network }
        return responses.removeFirst()
    }
}

private func response(_ text: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: Data(text.utf8))
}
private let token = #"{"access_token":"temporary-test-token","token_type":"Bearer","refresh_token":"persistent-test-token"}"#
private let renewed = #"{"access_token":"renewed-test-token","token_type":"Bearer"}"#
private let device = #"{"devices":[{"type":"sdm.devices.types.THERMOSTAT","name":"private-device-id","parentRelations":[{"displayName":"Sample room"}],"traits":{"sdm.devices.traits.Connectivity":{"status":"ONLINE"},"sdm.devices.traits.Temperature":{"ambientTemperatureCelsius":21.5},"sdm.devices.traits.Humidity":{"ambientHumidityPercent":52},"sdm.devices.traits.ThermostatMode":{"mode":"HEAT"},"sdm.devices.traits.ThermostatHvac":{"status":"OFF"},"sdm.devices.traits.ThermostatEco":{"mode":"OFF"},"sdm.devices.traits.ThermostatTemperatureSetpoint":{"heatCelsius":18}}}]}"#

private func redirect(_ reader: NestReader) async throws -> String {
    let auth = try await reader.authorizationURL()
    let parts = try #require(URLComponents(url: auth, resolvingAgainstBaseURL: false))
    let state = try #require(parts.queryItems?.first(where: { $0.name == "state" })?.value)
    return "https://www.google.com/?code=one-use-test-code&state=\(state)"
}

@Test func persistsBeforeReadAndRefreshesAcrossInstances() async throws {
    let store = Store(config())
    let http = HTTP([response(token), response(device), response(renewed), response(device)])
    let first = NestReader(store: store, http: http, now: { moment })
    let result = try await first.connect(redirect: redirect(first))
    #expect(result.thermostats.first?.temperatureCelsius == 21.5)
    #expect(try store.load()?.refreshToken == "persistent-test-token")
    #expect(try store.load()?.pendingState == nil)
    let relaunched = NestReader(store: store, http: http, now: { moment })
    let next = try await relaunched.read()
    #expect(next.thermostats.first?.hvac == "OFF")
    #expect(try store.load()?.refreshToken == "persistent-test-token")
    let requests = await http.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "POST", "GET"])
    let form = String(data: try #require(requests[2].httpBody), encoding: .utf8) ?? ""
    #expect(form.contains("grant_type=refresh_token"))
    #expect(form.contains("client_secret=test-secret%2B%26%3D"))
    #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer renewed-test-token")
    let json = String(data: try JSONEncoder().encode(next), encoding: .utf8) ?? ""
    #expect(!json.contains("private-device-id"))
    #expect(!json.contains("test-token"))
}

@Test func apiFailureDoesNotLoseRefreshToken() async throws {
    let store = Store(config())
    let http = HTTP([response(token), response("{}", status: 503), response(renewed), response(device)])
    let reader = NestReader(store: store, http: http, now: { moment })
    let url = try await redirect(reader)
    await #expect(throws: ReaderError.http(503)) { try await reader.connect(redirect: url) }
    #expect(try store.load()?.refreshToken == "persistent-test-token")
    let readings = try await NestReader(store: store, http: http).read()
    #expect(readings.thermostats.count == 1)
}

@Test func keychainFailureDoesNotConsumeCode() async throws {
    let store = Store(config()); let http = HTTP([response(token)])
    let reader = NestReader(store: store, http: http, now: { moment })
    let url = try await redirect(reader)
    store.rejectWrites()
    await #expect(throws: ReaderError.keychain(-1)) { try await reader.connect(redirect: url) }
    #expect(await http.requests.isEmpty)
}

@Test func rotatedRefreshTokenIsRetained() async throws {
    var c = config(); c.refreshToken = "original"
    let store = Store(c)
    let http = HTTP([response(token), response(device)])
    _ = try await NestReader(store: store, http: http).read()
    #expect(try store.load()?.refreshToken == "persistent-test-token")
}

@Test func invalidGrantIsActionableAndDoesNotLeakOrDelete() async throws {
    var c = config(); c.refreshToken = "original"
    let store = Store(c)
    let http = HTTP([response(#"{"error":"invalid_grant","error_description":"secret-token-and-personal-info"}"#, status: 400)])
    await #expect(throws: ReaderError.reauthorize) { try await NestReader(store: store, http: http).read() }
    #expect(try store.load()?.refreshToken == "original")
    #expect(!ReaderError.reauthorize.localizedDescription.contains("secret-token"))
    #expect(await http.requests.count == 1)
}

@Test func stateIsRequiredUniqueAndBoundToNewestAttempt() async throws {
    let reader = NestReader(store: Store(config()), http: HTTP([]), now: { moment })
    let old = try await redirect(reader)
    let latest = try await redirect(reader)
    #expect(old != latest)
    await #expect(throws: ReaderError.invalidRedirect) { try await reader.connect(redirect: old) }
    for text in ["https://www.google.com/?code=c", "https://example.com/?code=c&state=s",
                 "https://www.google.com/?code=c&state=s&state=s", "https://www.google.com/?code=a&code=b&state=s",
                 "https://www.google.com/?error=access_denied&code=c&state=s",
                 "https://user@www.google.com/?code=c&state=s", "https://www.google.com/other?code=c&state=s"] {
        #expect(throws: ReaderError.invalidRedirect) { try NestReader.authorizationCode(text, state: "s") }
    }
    #expect(try NestReader.authorizationCode(#"https://www.google.com/\?code\=valid%2Bcode\&state\=s"#, state: "s") == "valid+code")
}

@Test func expiresPendingAuthorizationBeforeSendingCode() async throws {
    let store = Store(config()); let http = HTTP([])
    let first = NestReader(store: store, http: http, now: { moment })
    let url = try await redirect(first)
    let later = NestReader(store: store, http: http, now: { moment.addingTimeInterval(1201) })
    await #expect(throws: ReaderError.expiredAuthorization) { try await later.connect(redirect: url) }
    #expect(await http.requests.isEmpty)
}

@Test func missingRefreshTokenDoesNotClaimPersistence() async throws {
    let store = Store(config()); let http = HTTP([response(renewed)])
    let reader = NestReader(store: store, http: http, now: { moment })
    let url = try await redirect(reader)
    await #expect(throws: ReaderError.missingRefreshToken) { try await reader.connect(redirect: url) }
    #expect(try store.load()?.refreshToken == nil)
    #expect(await http.requests.count == 1)
}

@Test func setupPreservesTokensButRejectsAccountSwitch() async throws {
    var old = config(); old.refreshToken = "retained"
    let store = Store(old); let reader = NestReader(store: store, http: HTTP([]))
    var updated = config(); updated.clientSecret = "changed"
    try await reader.setup(updated)
    #expect(try store.load()?.refreshToken == "retained")
    #expect(try store.load()?.clientSecret == "changed")
    updated.projectID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let different = updated
    await #expect(throws: ReaderError.differentAccount) { try await reader.setup(different) }
}

@Test func importsOnlyValidWebClients() throws {
    let valid = Data(#"{"web":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":"synthetic","token_uri":"https://untrusted.invalid"}}"#.utf8)
    #expect(try Credentials.imported(valid, projectID: project).clientSecret == "synthetic")
    #expect(throws: ReaderError.invalidConfiguration) { try Credentials.imported(valid, projectID: "not-a-uuid") }
    #expect(throws: ReaderError.invalidConfiguration) { try Credentials.imported(Data("{}".utf8), projectID: project) }
}

@Test func onlyTokenExchangeAndReadOnlyGoogleEndpointAreAllowed() throws {
    for (method, url, allowed) in [
        ("POST", "https://oauth2.googleapis.com/token", true),
        ("GET", "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(project)/devices", true),
        ("POST", "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(project)/devices", false),
        ("POST", "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(project)/devices/a:executeCommand", false),
        ("POST", "http://oauth2.googleapis.com/token", false),
        ("POST", "https://untrusted.invalid/token", false),
        ("POST", "https://oauth2.googleapis.com/token?secret=x", false),
        ("POST", "https://user@oauth2.googleapis.com/token", false),
        ("POST", "https://oauth2.googleapis.com:444/token", false),
        ("GET", "https://smartdevicemanagement.googleapis.com/v1/enterprises/invalid/devices", false)
    ] {
        var r = URLRequest(url: try #require(URL(string: url))); r.httpMethod = method
        #expect(GoogleHTTPClient.permits(r) == allowed)
    }
}

@Test func ecoOfflineAndMissingValuesAreExplicit() throws {
    let data = Data(#"{"devices":[{"type":"sdm.devices.types.THERMOSTAT","traits":{"sdm.devices.traits.Connectivity":{"status":"OFFLINE"},"sdm.devices.traits.ThermostatEco":{"mode":"MANUAL_ECO","heatCelsius":10,"coolCelsius":25}}}]}"#.utf8)
    let result = try Readings.decode(data, fetchedAt: moment)
    #expect(result.text.contains("may be stale"))
    #expect(result.text.contains("Eco heating threshold: 50.0°F"))
    #expect(result.text.contains("Temperature: Unavailable"))
    #expect(result.thermostats[0].heatCelsius == nil)
}

@Test func malformedAndOversizedDataAreRejected() throws {
    for text in ["not-json", #"{"devices":true}"#,
                 device.replacingOccurrences(of: "21.5", with: "true"),
                 device.replacingOccurrences(of: "21.5", with: "9999")] {
        #expect(throws: ReaderError.malformedResponse) { try Readings.decode(Data(text.utf8), fetchedAt: moment) }
    }
    #expect(throws: ReaderError.responseTooLarge) {
        try NestReader.validate(HTTPResponse(status: 200, body: Data(repeating: 0, count: 1_048_577)))
    }
    #expect(try Readings.decode(Data("{}".utf8), fetchedAt: moment).thermostats.isEmpty)
}

@Test func expiryAndRateLimitDoNotRequireBlindRetry() async throws {
    var c = config(); c.refreshToken = "retained"; c.refreshExpiresAt = moment.addingTimeInterval(-1)
    let http = HTTP([])
    await #expect(throws: ReaderError.reauthorize) {
        try await NestReader(store: Store(c), http: http, now: { moment }).read()
    }
    #expect(await http.requests.isEmpty)
    #expect(throws: ReaderError.rateLimited) { try NestReader.validate(response("{}", status: 429)) }
    #expect(throws: ReaderError.permissionDenied) { try NestReader.validate(response("{}", status: 403)) }
    #expect(throws: ReaderError.http(302)) { try NestReader.validate(response("{}", status: 302)) }
}

private let controlResource = "enterprises/" + project + "/devices/synthetic-device"
private var controllableDevice: String {
    device.replacingOccurrences(of: "private-device-id", with: controlResource)
        .replacingOccurrences(of: #""mode":"HEAT""#, with: #""mode":"HEAT","availableModes":["HEAT","OFF"]"#)
}

private var singleDevice: String {
    let root = try! JSONSerialization.jsonObject(with: Data(controllableDevice.utf8)) as! [String: Any]
    return String(data: try! JSONSerialization.data(withJSONObject: (root["devices"] as! [[String: Any]])[0]), encoding: .utf8)!
}

@Test func readerControlIsExplicitlyOptIn() async throws {
    let http = HTTP([])
    let reader = NestReader(store: Store(config()), http: http)
    await #expect(throws: ReaderError.permissionDenied) { try await reader.execute(.heat(20), resource: controlResource) }
    #expect(await http.requests.isEmpty)
}

@Test func thermostatWriteChecksFreshStateAndReadsBack() async throws {
    var c = config(); c.refreshToken = "synthetic-refresh"
    let http = HTTP([response(renewed), response(controllableDevice), response("{}"), response(singleDevice)])
    let reader = NestReader(store: Store(c), http: http, allowsControl: true)
    _ = try await reader.execute(.heat(20), resource: controlResource)
    let requests = await http.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "POST", "GET"])
    #expect(requests[2].url?.path.hasSuffix(":executeCommand") == true)
    #expect(requests[3].url?.path == "/v1/" + controlResource)
    #expect(GoogleHTTPClient.permits(requests[3]))
    #expect(!GoogleHTTPClient.permits(requests[2]))
    #expect(NestCommand.permits(requests[2]))
    let data = try #require(requests[2].httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["command"] as? String == "sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat")
    #expect((body["params"] as? [String: Double])?["heatCelsius"] == 20)
}

@Test func commandsRejectEcoOfflineUnsupportedModesAndBadRanges() throws {
    let t = try #require(Readings.decode(Data(controllableDevice.utf8), fetchedAt: moment).thermostats.first)
    for command in [NestCommand.heat(.nan), .heat(100), .cool(20), .mode("COOL"), .range(heat: 22, cool: 20)] {
        #expect(throws: ReaderError.invalidCommand) { try command.body(for: t) }
    }
    // Replace the trait's exact value without changing HVAC or thermostat mode.
    let ecoData = controllableDevice.replacingOccurrences(of: #""sdm.devices.traits.ThermostatEco":{"mode":"OFF"}"#, with: #""sdm.devices.traits.ThermostatEco":{"mode":"MANUAL_ECO"}"#)
    let eco = try #require(Readings.decode(Data(ecoData.utf8), fetchedAt: moment).thermostats.first)
    #expect(throws: ReaderError.invalidCommand) { try NestCommand.heat(20).body(for: eco) }
    let offlineData = controllableDevice.replacingOccurrences(of: "ONLINE", with: "OFFLINE")
    let offline = try #require(Readings.decode(Data(offlineData.utf8), fetchedAt: moment).thermostats.first)
    #expect(throws: ReaderError.network) { try NestCommand.heat(20).body(for: offline) }
}

@Test func ambiguousCommandIsNeverReplayed() async throws {
    var c = config(); c.refreshToken = "synthetic-refresh"
    let http = HTTP([response(renewed), response(controllableDevice), response("{}", status: 503)])
    let reader = NestReader(store: Store(c), http: http, allowsControl: true)
    await #expect(throws: ReaderError.http(503)) { try await reader.execute(.heat(20), resource: controlResource) }
    #expect(await http.requests.count == 3)
}

@Test func commandEndpointIsRestrictedToKnownThermostatCommands() throws {
    let t = try #require(Readings.decode(Data(controllableDevice.utf8), fetchedAt: moment).thermostats.first)
    let url = try #require(URL(string: "https://smartdevicemanagement.googleapis.com/v1/" + controlResource + ":executeCommand"))
    var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try NestCommand.heat(20).body(for: t)
    #expect(NestCommand.permits(request)); #expect(!GoogleHTTPClient.permits(request))
    request.httpBody = Data(#"{"command":"sdm.devices.commands.CameraLiveStream.GenerateRtspStream","params":{}}"#.utf8)
    #expect(!NestCommand.permits(request))
    #expect(!NestCommand.validResource("enterprises/" + project + "/devices/../../other", project: project))
    #expect(!NestCommand.validResource("enterprises/" + project + "/devices/x?token=y", project: project))
}

@Test func rateLimitBlocksFurtherRequestsWithoutReplayingCommand() async throws {
    var c = config(); c.refreshToken = "synthetic-refresh"
    let http = HTTP([response(renewed), response(controllableDevice),
                     HTTPResponse(status: 429, body: Data("{}".utf8), retryAfter: 120)])
    let reader = NestReader(store: Store(c), http: http, now: { moment }, allowsControl: true)
    await #expect(throws: ReaderError.rateLimited) { try await reader.execute(.heat(20), resource: controlResource) }
    #expect(await reader.retryNotBefore == moment.addingTimeInterval(120))
    await #expect(throws: ReaderError.rateLimited) { try await reader.read() }
    await #expect(throws: ReaderError.rateLimited) { try await reader.execute(.heat(21), resource: controlResource) }
    #expect(await http.requests.count == 3)
}

@Test func singleDeviceReadRejectsWrongDeviceAndUnsafePaths() throws {
    let readings = try Readings.decode(Data(controllableDevice.utf8), fetchedAt: moment)
    #expect(throws: ReaderError.malformedResponse) {
        try readings.replacingDevice(Data(singleDevice.utf8), resource: "other", fetchedAt: moment)
    }
    for suffix in ["a:executeCommand", "a/extra", "a?token=x", "a#fragment", "%2E%2E"] {
        let request = URLRequest(url: URL(string: "https://smartdevicemanagement.googleapis.com/v1/enterprises/" + project + "/devices/" + suffix)!)
        #expect(!GoogleHTTPClient.permits(request))
    }
}

@Test func retryAfterHandlesSecondsDatesAndInvalidValues() {
    #expect(GoogleHTTPClient.retryDelay("120") == 120)
    #expect(GoogleHTTPClient.retryDelay("nan") == nil)
    #expect(GoogleHTTPClient.retryDelay("-1") == nil)
    #expect(GoogleHTTPClient.retryDelay("Wed, 21 Oct 2015 07:28:00 GMT", now: Date(timeIntervalSince1970: 1445412420)) == 60)
}
