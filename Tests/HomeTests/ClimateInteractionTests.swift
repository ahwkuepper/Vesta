import Foundation
import Testing
import NestCore
@testable import HomeUI

private let climateProject = "11111111-2222-3333-4444-555555555555"
private let climateResource = "enterprises/" + climateProject + "/devices/synthetic-device"
private func climateData(mode: String = "HEAT", heat: Double = 20, cool: Double = 24) -> Data {
    Data("""
    {"devices":[{"type":"sdm.devices.types.THERMOSTAT","name":"\(climateResource)","traits":{
    "sdm.devices.traits.Connectivity":{"status":"ONLINE"},
    "sdm.devices.traits.ThermostatMode":{"mode":"\(mode)","availableModes":["HEAT","COOL","HEATCOOL","OFF"]},
    "sdm.devices.traits.ThermostatEco":{"mode":"OFF"},
    "sdm.devices.traits.ThermostatTemperatureSetpoint":{"heatCelsius":\(heat),"coolCelsius":\(cool)}}}]}
    """.utf8)
}
private final class ClimateStore: CredentialStore, @unchecked Sendable {
    func load() throws -> Credentials? {
        var c = Credentials(projectID: climateProject, clientID: "synthetic.apps.googleusercontent.com", clientSecret: "synthetic")
        c.refreshToken = "synthetic-refresh"; return c
    }
    func save(_ value: Credentials) throws {}
    func delete() throws {}
}
private actor ClimateHTTP: HTTPClient {
    var requests: [URLRequest] = []
    let limited: Bool
    init(limited: Bool = false) { self.limited = limited }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url?.host == "oauth2.googleapis.com" {
            return HTTPResponse(status: 200, body: Data(#"{"access_token":"synthetic","token_type":"Bearer"}"#.utf8))
        }
        if request.httpMethod == "POST" {
            return HTTPResponse(status: limited ? 429 : 200, body: Data("{}".utf8))
        }
        if request.url?.path.hasSuffix("/devices") == true { return HTTPResponse(status: 200, body: climateData()) }
        let root = try JSONSerialization.jsonObject(with: climateData(heat: 21.5)) as! [String: Any]
        let device = (root["devices"] as! [[String: Any]])[0]
        return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: device))
    }
}

@Suite("Climate interaction", .serialized) @MainActor
struct ClimateInteractionTests {
    private func model(_ http: ClimateHTTP = ClimateHTTP(), mode: String = "HEAT") throws -> HomeModel {
        let reader = NestReader(store: ClimateStore(), http: http, allowsControl: true)
        let model = HomeModel(preferences: nil, nest: reader)
        model.celsius = true
        model.nestReadings = try Readings.decode(climateData(mode: mode), fetchedAt: Date())
        return model
    }
    @Test func rapidTapsAccumulateAndSendOnlyFinalTargetAfterPause() async throws {
        let http = ClimateHTTP(); let model = try model(http)
        model.stepTarget(1); model.stepTarget(1); model.stepTarget(1)
        #expect(model.targetTemperature(cooling: false) == 21.5)
        #expect(model.thermostat?.heatCelsius == 20)
        #expect(await http.requests.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await http.requests.isEmpty)
        // Wait with a bounded deadline for the real debounce, without touching hardware.
        for _ in 0..<100 {
            if model.targetDraft == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.targetDraft == nil)
        let requests = await http.requests
        let writes = requests.filter { $0.url?.path.hasSuffix(":executeCommand") == true }
        #expect(writes.count == 1)
        let body = try #require(writes.first?.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect((object["params"] as? [String: Double])?["heatCelsius"] == 21.5)
        #expect(requests.count == 4)
    }
    @Test func returnToOriginalAndSelectionChangeCancelDraft() async throws {
        let http = ClimateHTTP(); let model = try model(http)
        model.celsius = false
        model.stepTarget(1); model.stepTarget(-1)
        #expect(model.targetDraft == nil)
        model.commitTarget()
        model.stepTarget(1); model.thermostatIndex = 1
        #expect(model.targetDraft == nil)
        model.commitTarget()
        #expect(await http.requests.isEmpty)
    }
    @Test func rangeAccumulatesBothEndsAndRespectsGapAndBounds() throws {
        let model = try model(mode: "HEATCOOL")
        model.stepTarget(1); model.stepTarget(1, cooling: true)
        #expect(model.targetDraft?.command == .range(heat: 20.5, cool: 24.5))
        model.stepTarget(100)
        #expect(model.targetTemperature(cooling: false) == 24)
        model.stepTarget(-100, cooling: true)
        #expect(model.targetTemperature(cooling: true) == 24.5)
        model.cancelTarget()
    }
    @Test func changedModeCancelsAndFreshReadIsReused() async throws {
        let http = ClimateHTTP(); let model = try model(http)
        model.stepTarget(1)
        model.nestReadings = try Readings.decode(climateData(mode: "COOL"), fetchedAt: Date())
        model.commitTarget()
        #expect(model.targetDraft == nil)
        await model.refreshNest()
        #expect(await http.requests.isEmpty)
    }
    @Test func rateLimitKeepsConfirmedValueAndDoesNotReadBackOrRetry() async throws {
        let http = ClimateHTTP(limited: true); let model = try model(http)
        model.stepTarget(1); model.commitTarget()
        for _ in 0..<100 {
            if !model.nestCommandBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.nestCommandBusy)
        #expect(model.nestRetryAt != nil)
        #expect(model.targetDraft == nil)
        #expect(model.targetTemperature(cooling: false) == 20)
        #expect(!model.climateWritable)
        model.stepTarget(1)
        await model.refreshNest(force: true)
        #expect(await http.requests.count == 3)
    }
}
