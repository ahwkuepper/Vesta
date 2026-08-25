import Foundation
@preconcurrency import CoreBluetooth
import LumoKit

/// The real transport. The only type in the project that touches CoreBluetooth.
///
/// Delegate callbacks arrive on a private queue and are hopped to the main actor
/// before touching any shared state, so no UI code ever sees a `CBPeripheral`.
public final class BLETransport: NSObject, LightTransport, @unchecked Sendable {

    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "dev.lumo.ble", qos: .userInitiated)

    /// Everything mutable lives here and is only touched on `queue`.
    private var peripherals: [Light.ID: CBPeripheral] = [:]
    private var characteristics: [Light.ID: [CBUUID: CBCharacteristic]] = [:]
    private var handler: (@MainActor (TransportEvent) -> Void)?
    /// Continuations for writes awaiting `didWriteValueFor`.
    private var pendingWrites: [WriteToken: CheckedContinuation<Void, Error>] = [:]

    private struct WriteToken: Hashable {
        let light: Light.ID
        let characteristic: CBUUID
    }

    public override init() {
        super.init()
    }

    // MARK: - LightTransport

    public func start(handler: @escaping @MainActor (TransportEvent) -> Void) async {
        queue.sync { self.handler = handler }
        // Constructing the manager is what triggers the TCC prompt, so it happens
        // here — behind an explicit user action — rather than at app launch.
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func stop() async {
        queue.sync {
            central?.stopScan()
            for p in peripherals.values { central?.cancelPeripheralConnection(p) }
        }
    }

    public func setPower(_ on: Bool, for id: Light.ID) async throws {
        try await write(HueProtocol.powerPayload(on), to: HueProtocol.power, on: id)
    }

    public func setBrightness(_ brightness: Double, for id: Light.ID) async throws {
        try await write(HueProtocol.brightnessPayload(brightness), to: HueProtocol.brightness, on: id)
    }

    public func setColor(_ color: LightColor, for id: Light.ID) async throws {
        switch color {
        case .temperature(let mireds):
            try await write(HueProtocol.temperaturePayload(mireds: mireds),
                            to: HueProtocol.temperature, on: id)
        case .xy(let x, let y):
            try await write(HueProtocol.colorPayload(x: x, y: y),
                            to: HueProtocol.color, on: id)
        }
    }

    // MARK: - Writing

    private func write(_ data: Data, to uuid: CBUUID, on id: Light.ID) async throws {
        let token = WriteToken(light: id, characteristic: uuid)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let peripheral = peripherals[id] else {
                    continuation.resume(throwing: TransportError.unknownLight); return
                }
                guard peripheral.state == .connected,
                      let characteristic = characteristics[id]?[uuid] else {
                    continuation.resume(throwing: TransportError.notConnected); return
                }

                // A superseded write for the same characteristic is resolved rather
                // than left dangling — the newer value is the one that matters.
                pendingWrites[token]?.resume()
                pendingWrites[token] = continuation
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    private func resolveWrite(_ token: WriteToken, error: Error?) {
        guard let continuation = pendingWrites.removeValue(forKey: token) else { return }
        if let error {
            continuation.resume(throwing: Self.translate(error))
        } else {
            continuation.resume()
        }
    }

    /// CoreBluetooth reports a missing BLE bond as a generic ATT error. Surfacing
    /// "Encryption is insufficient" to a user is useless; they need to be told the
    /// light has to be paired.
    private static func translate(_ error: Error) -> TransportError {
        let message = error.localizedDescription.lowercased()
        if message.contains("encryption") || message.contains("authentication") {
            return .needsPairing
        }
        return .writeFailed(error.localizedDescription)
    }

    private func emit(_ event: TransportEvent) {
        guard let handler else { return }
        Task { @MainActor in handler(event) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            emit(.availabilityChanged(.ready))
            manager.scanForPeripherals(withServices: [HueProtocol.advertisedService],
                                       options: nil)
        case .unauthorized: emit(.availabilityChanged(.unauthorized))
        case .poweredOff:   emit(.availabilityChanged(.poweredOff))
        case .unsupported:  emit(.availabilityChanged(.unsupported))
        default: break
        }
    }

    public func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let isNew = peripherals[id] == nil
        peripherals[id] = peripheral
        peripheral.delegate = self

        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Hue light"

        emit(.discovered(Light(id: id, name: name, connection: .connecting, rssi: RSSI.intValue)))

        if isNew {
            manager.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([HueProtocol.controlService, HueProtocol.deviceInfoService])
    }

    public func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        emit(.connectionChanged(id: peripheral.identifier, connection: .unreachable))
    }

    public func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        characteristics[peripheral.identifier] = nil
        emit(.connectionChanged(id: peripheral.identifier, connection: .unreachable))
        // Reconnect automatically. This is a laptop — walking to the next room and
        // back is a normal thing to do, not an error the user should have to fix.
        manager.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            let wanted = service.uuid == HueProtocol.controlService
                ? HueProtocol.controlCharacteristics
                : [HueProtocol.modelNumber, HueProtocol.manufacturer, HueProtocol.firmware]
            peripheral.discoverCharacteristics(wanted, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let id = peripheral.identifier
        for characteristic in service.characteristics ?? [] {
            characteristics[id, default: [:]][characteristic.uuid] = characteristic

            if HueProtocol.controlCharacteristics.contains(characteristic.uuid) {
                // Subscribe rather than poll, so state stays correct when someone
                // uses the Hue app or a physical switch.
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                peripheral.readValue(for: characteristic)
            } else {
                peripheral.readValue(for: characteristic)
            }
        }

        if service.uuid == HueProtocol.controlService {
            emit(.connectionChanged(id: id, connection: .ready))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        let id = peripheral.identifier

        if let error {
            // A read that fails on encryption grounds is the bulb telling us it has
            // no bond with this Mac. That is a distinct, actionable state.
            if Self.translate(error) == .needsPairing {
                emit(.connectionChanged(id: id, connection: .needsPairing))
            }
            return
        }

        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case HueProtocol.modelNumber:
            if let model = String(data: data, encoding: .utf8) {
                emit(.discovered(Light(id: id, name: peripheral.name ?? "Hue light",
                                       model: model, connection: .ready)))
            }
        case HueProtocol.power, HueProtocol.brightness,
             HueProtocol.temperature, HueProtocol.color:
            if let state = decodeState(for: characteristic, peripheral: peripheral) {
                emit(.stateChanged(id: id, delta: LightStateDelta(state)))
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        let token = WriteToken(light: peripheral.identifier, characteristic: characteristic.uuid)
        resolveWrite(token, error: error)

        if let error, Self.translate(error) == .needsPairing {
            emit(.connectionChanged(id: peripheral.identifier, connection: .needsPairing))
        }
    }

    /// Rebuilds a full `LightState` from whatever characteristics have been read so
    /// far — they arrive one callback at a time, but the model is a whole value.
    private func decodeState(for characteristic: CBCharacteristic,
                             peripheral: CBPeripheral) -> LightState? {
        let cached = characteristics[peripheral.identifier] ?? [:]

        let isOn = cached[HueProtocol.power]?.value.flatMap(HueProtocol.decodePower) ?? false
        let brightness = cached[HueProtocol.brightness]?.value.flatMap(HueProtocol.decodeBrightness) ?? 0.5

        var color = LightColor.temperature(mireds: 366)
        if let xy = cached[HueProtocol.color]?.value.flatMap(HueProtocol.decodeColor), xy.x > 0 {
            color = .xy(x: xy.x, y: xy.y)
        } else if let mireds = cached[HueProtocol.temperature]?.value.flatMap(HueProtocol.decodeTemperature),
                  mireds > 0 {
            color = .temperature(mireds: mireds)
        }

        return LightState(isOn: isOn, brightness: brightness, color: color)
    }
}
