// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import KasaKit
@testable import KasaTransport
@testable import KasaUI

private func hex(_ string: String) -> Data {
    var bytes = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let end = string.index(index, offsetBy: 2)
        if let byte = UInt8(string[index..<end], radix: 16) { bytes.append(byte) }
        index = end
    }
    return bytes
}

@Suite("Kasa wire protocol")
struct KasaWireTests {
    let payload = Data(#"{"system":{"get_sysinfo":{}}}"#.utf8)

    @Test("Both KLAP generations match independent reference vectors")
    func knownCiphertext() throws {
        // Synthetic credentials and seeds; vectors produced by python-kasa 0.10.2.
        let keys = KasaCredentials(email: "test@example.invalid", password: "synthetic-test-password")
        #expect(keys.v1 == hex("752fd0fa34ea1081d7307d4ce07c75e3"))
        #expect(keys.v2 == hex("4ce2b1ee45c613389562cd019fe4b49ef361f21781329f8049689dd73a515ce8"))
        for (auth, expected, sequence) in [
            (keys.v1, "8ee8455ebfa01601fd2de2b4ca0aa2919492bcf5ce468ff5eb029dbb8786f8575154f9559b8786c01411aeca946c15771404fe87df62a6b1b88ee6650cb7a3f7", Int32(-664716810)),
            (keys.v2, "a2b0ce3e10e903c4a94b93b94716e71f326bb9bcac10e84d5143a88b3f1effab89eb3c9662122ae8c7b6d7a14d07bdfb614e3e6cdc39ac275ce1ef2419681542", Int32(256146875))
        ] {
            var cipher = try KasaCipher(local: Data(0..<16), remote: Data(16..<32), auth: auth)
            let sealed = try cipher.seal(payload)
            #expect(sealed == hex(expected))
            #expect(Int32(bitPattern: cipher.sequence) == sequence)
            #expect(try cipher.open(sealed) == payload)
            var tampered = sealed
            tampered[0] ^= 1
            #expect(throws: KasaError.invalidResponse) { try cipher.open(tampered) }
            _ = try cipher.seal(payload)
            #expect(throws: KasaError.invalidResponse) { try cipher.open(sealed) }
        }
    }

    @Test("Legacy cipher has a known prefix and round-trips all byte values")
    func legacy() {
        #expect(KasaCrypto.xorEncode(Data("{\"".utf8)) == Data([0xd0, 0xf2]))
        let input = Data((0...255).map(UInt8.init))
        #expect(KasaCrypto.xorDecode(KasaCrypto.xorEncode(input)) == input)
    }

    @Test("Reject truncated packets, oversized objects and invalid integers")
    func malformed() throws {
        #expect(throws: (any Error).self) { try KasaCoding.object(Data()) }
        #expect(throws: (any Error).self) { try KasaCoding.object(Data(repeating: 32, count: KasaCoding.limit + 1)) }
        #expect(throws: (any Error).self) { try KasaCoding.discovery(Data([0,1]), host: "192.0.2.1", port: 20002) }
        #expect(KasaCoding.integer(NSNumber(value: 1e90), in: 0...100) == nil)
        #expect(KasaCoding.integer(NSNumber(value: 1.5), in: 0...100) == nil)
        #expect(KasaCoding.integer(NSNumber(value: -1), in: 0...100) == nil)
        #expect(throws: KasaError.invalidResponse) { try KasaCrypto.number(Data([0])) }
        #expect(throws: KasaError.invalidResponse) { try KasaCipher(local: Data(), remote: Data(), auth: Data()) }
    }

    @Test("LAN policy rejects public, loopback, malformed, network and broadcast addresses")
    func lan() throws {
        #expect(LocalNetwork.privateAddress(0xc0a80109))
        #expect(LocalNetwork.privateAddress(0x0a000001))
        #expect(LocalNetwork.privateAddress(0xac100001))
        #expect(!LocalNetwork.privateAddress(0xac200001))
        #expect(!LocalNetwork.privateAddress(0x08080808))
        #expect(!LocalNetwork.privateAddress(0x7f000001))
        #expect(LocalNetwork.parse("example.invalid") == nil)
        #expect(LocalNetwork.parse("127.0.0.1/path") == nil)
        let subnet = LocalNetwork.Subnet(address: 0xc0a80109, mask: 0xffffff00)
        #expect(subnet.contains(0xc0a80110))
        #expect(!subnet.contains(0xc0a801ff))
        #expect(!subnet.contains(0xc0a80100))
        #expect(!subnet.contains(0xc0a80210))
        #expect(throws: KasaError.localNetwork) { try LocalNetwork.requireLocal("203.0.113.4") }
    }

    @Test("Discovery never follows the IP supplied by a device")
    func discovery() throws {
        let info: [String: Any] = ["result": ["device_type": "IOT.SMARTBULB", "device_model": "KL110", "mac": "AA-BB-CC-11-22-33",
            "ip": "203.0.113.9", "mgt_encrypt_schm": ["encrypt_type": "KLAP", "http_port": 80, "lv": 2]]]
        let packet = Data(repeating: 0, count: 16) + (try JSONSerialization.data(withJSONObject: info))
        let device = try KasaCoding.discovery(packet, host: "192.0.2.1", port: 20002)
        #expect(device.host == "192.0.2.1")
        #expect(device.transport == .klap)
        #expect(device.connection == .signInRequired)
        #expect(device.isBulb)
    }

    @Test("Unsupported newer protocols remain visible but cannot be controlled")
    func unsupported() throws {
        let info: [String: Any] = ["result": ["device_type": "SMART.TAPOPLUG", "device_model": "P100",
            "mgt_encrypt_schm": ["encrypt_type": "AES", "http_port": 80]]]
        let packet = Data(repeating: 0, count: 16) + (try JSONSerialization.data(withJSONObject: info))
        let device = try KasaCoding.discovery(packet, host: "192.0.2.1", port: 20002)
        #expect(device.connection == .unsupported)
        #expect(!device.canControl)
    }

    @Test("Off bulbs retain brightness and temperature from their default-on state")
    func offBulb() throws {
        let response: [String: Any] = ["system": ["get_sysinfo": ["err_code": 0, "alias": "Test bulb", "model": "KL130", "mac": "AA:BB:CC:11:22:33",
            "is_dimmable": 1, "is_color": 1, "is_variable_color_temp": 1,
            "light_state": ["on_off": 0, "dft_on_state": ["brightness": 68, "color_temp": 2700, "hue": 0, "saturation": 0]]]]]
        let base = KasaDevice(id: "test", host: "192.0.2.1", name: "Test", model: "KL130")
        let device = try #require(KasaCoding.devices(response, base: base).first)
        #expect(!device.isOn)
        #expect(device.brightness == 68)
        #expect(device.supportsColor && device.supportsTemperature)
        #expect(device.colorTemperature == 2700)
        #expect(device.id == KasaCoding.identity(["mac": "AA-BB-CC-11-22-33"], host: base.host))
    }

    @Test("Power-strip commands address only the selected outlet")
    func strip() throws {
        let response: [String: Any] = ["system": ["get_sysinfo": ["err_code": 0, "alias": "Desk strip", "mac": "AA:BB:CC:11:22:33",
            "children": [["id": "01", "alias": "Monitor", "state": 1], ["id": "02", "alias": "Lamp", "state": 0]]]]]
        let base = KasaDevice(id: "test", host: "192.0.2.1", name: "Test", model: "HS300")
        let outlets = try KasaCoding.devices(response, base: base)
        #expect(outlets.count == 2)
        #expect(outlets[0].id != outlets[1].id)
        let command = try KasaCoding.object(KasaCoding.request(.power(false), device: outlets[0]))
        let context = try #require(command["context"] as? [String: Any])
        #expect(context["child_ids"] as? [String] == ["01"])
        #expect(throws: KasaError.unsupported) { try KasaCoding.request(.brightness(42), device: outlets[0]) }
    }

    @Test("Commands preserve schedules and refuse unsupported capabilities")
    func commands() throws {
        let bulb = KasaDevice(id: "test", host: "192.0.2.1", name: "Test", model: "KL110", isBulb: true, brightness: 50)
        let request = try KasaCoding.object(KasaCoding.request(.brightness(60), device: bulb))
        #expect(request.count == 1)
        let service = try #require(request["smartlife.iot.smartbulb.lightingservice"] as? [String: Any])
        let state = try #require(service["transition_light_state"] as? [String: Any])
        #expect(state["brightness"] as? Int == 60)
        #expect(state["on_off"] == nil)
        #expect(throws: KasaError.unsupported) { try KasaCoding.request(.temperature(3000), device: bulb) }
        #expect(throws: KasaError.unsupported) { try KasaCoding.request(.brightness(101), device: bulb) }
        #expect(throws: KasaError.rejected(-1)) { try KasaCoding.checkErrors(["system": ["set_relay_state": ["err_code": -1]]]) }
    }
}

@Suite("Kasa menu state")
@MainActor
struct KasaModelTests {
    @Test("Power changes are scoped to one device")
    func individualPower() async throws {
        let model = KasaModel(demo: true)
        let before = model.devices
        let target = try #require(model.lights.first)
        model.command(.power(false), device: target)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.devices.first { $0.id == target.id }?.isOn == false)
        #expect(model.devices.filter { !$0.isBulb } == before.filter { !$0.isBulb })
    }

    @Test("Dragging brightness keeps only the last pending value")
    func brightness() async throws {
        let model = KasaModel(demo: true)
        let target = try #require(model.lights.first)
        for value in [20,40,80] { model.setBrightness(value, for: target) }
        #expect(model.brightnessDraft[target.id] == 80)
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.devices.first { $0.id == target.id }?.brightness == 80)
        #expect(model.brightnessDraft[target.id] == nil)
        #expect(model.busy.isEmpty)
    }

    @Test("Search covers names and models")
    func search() {
        let model = KasaModel(demo: true)
        model.search = "kl110"
        #expect(model.lights.count == 2)
        #expect(model.plugs.isEmpty)
    }
}

private actor KasaTestService: KasaServing {
    var device = KasaDevice(id: "fixture", host: "192.0.2.1", name: "Fixture", model: "HS105")
    var writes = 0
    var reading = false
    var failWrite = false
    var slowRead = false
    private var readStarted: CheckedContinuation<Void, Never>?
    private var readRelease: CheckedContinuation<Void, Never>?

    func waitForRead() async {
        if reading { return }
        await withCheckedContinuation { readStarted = $0 }
    }
    func releaseRead() { readRelease?.resume(); readRelease = nil }

    func configure(failWrite: Bool = false, slowRead: Bool = false) {
        self.failWrite = failWrite; self.slowRead = slowRead
    }
    func discover() async throws -> [KasaDevice] { [device] }
    func read(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> [KasaDevice] {
        let snapshot = self.device
        if slowRead {
            slowRead = false
            reading = true
            readStarted?.resume(); readStarted = nil
            await withCheckedContinuation { readRelease = $0 }
            reading = false
        }
        return [snapshot]
    }
    func apply(_ command: KasaCommand, to device: KasaDevice, credentials: KasaCredentials?) async throws {
        writes += 1
        if case .power(let on) = command { self.device.isOn = on }
        if failWrite { throw KasaError.unavailable }
    }
}

@Suite("Kasa refresh and recovery")
@MainActor
struct KasaRecoveryTests {
    @Test("A stale refresh cannot overwrite a completed command")
    func staleRefresh() async throws {
        let service = KasaTestService()
        let model = KasaModel(client: service, preferences: nil)
        await model.refresh(discover: true)
        let device = try #require(model.devices.first)
        await service.configure(slowRead: true)
        let refresh = Task { await model.refresh() }
        await service.waitForRead()
        let command = model.command(.power(true), device: device)
        await command?.value
        await service.releaseRead()
        await refresh.value
        #expect(model.devices.first?.isOn == true)
        #expect(await service.writes == 1)
    }

    @Test("A lost command reply is reconciled without a second write")
    func lostReply() async throws {
        let service = KasaTestService()
        let model = KasaModel(client: service, preferences: nil)
        await model.refresh(discover: true)
        let device = try #require(model.devices.first)
        await service.configure(failWrite: true)
        let command = model.command(.power(true), device: device)
        await command?.value
        #expect(await service.writes == 1)
        #expect(model.devices.first?.isOn == true)
        #expect(model.error != nil)
        #expect(model.busy.isEmpty)
    }
}
