// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The seam between the app and whatever is actually driving the bulbs.
///
/// Everything above this protocol — the entire UI, scenes, persistence — is
/// independent of Bluetooth. That is what makes it possible to build the app while
/// the BLE bonding question is still open, and what would make a swap to a Hue
/// Bridge transport a change of one file rather than a rewrite.
public protocol LightTransport: Sendable {
    /// Begin discovery. Events arrive on the main actor.
    func start(handler: @escaping @MainActor (TransportEvent) -> Void) async

    func stop() async

    func setPower(_ on: Bool, for id: Light.ID) async throws
    func setBrightness(_ brightness: Double, for id: Light.ID) async throws
    func setColor(_ color: LightColor, for id: Light.ID) async throws
    /// Sets a multi-point gradient on fixtures that have one.
    func setGradient(_ gradient: LightGradient, for id: Light.ID) async throws
    /// Applies one of the bridge's built-in effects, or `nil` to clear it.
    func setEffect(_ effect: String?, for id: Light.ID) async throws

    // Rooms and scenes live on a bridge. Transports without them inherit the
    // defaults below rather than each having to stub them out.
    /// Current state of every light, for reconciling after the transport applies
    /// something we did not compute — recalling a scene, most importantly.
    func fetchLights() async throws -> [Light]
    func fetchRooms() async throws -> [Room]
    func fetchScenes() async throws -> [RoomScene]
    func recallScene(_ id: RoomScene.ID) async throws
    /// `actions` empty means: capture whatever the room is doing right now.
    func createScene(named name: String, in room: Room.ID, actions: [SceneAction]) async throws -> RoomScene
    func deleteScene(_ id: RoomScene.ID) async throws
    /// Sets a whole room at once where the transport can; otherwise per-light.
    func setRoomPower(_ on: Bool, room: Room) async throws
}

public extension LightTransport {
    func setGradient(_ gradient: LightGradient, for id: Light.ID) async throws {
        throw TransportError.unsupported
    }
    func setEffect(_ effect: String?, for id: Light.ID) async throws {
        throw TransportError.unsupported
    }
    func fetchLights() async throws -> [Light] { [] }
    func fetchRooms() async throws -> [Room] { [] }
    func fetchScenes() async throws -> [RoomScene] { [] }
    func recallScene(_ id: RoomScene.ID) async throws { throw TransportError.unsupported }
    func createScene(named name: String, in room: Room.ID,
                     actions: [SceneAction]) async throws -> RoomScene {
        throw TransportError.unsupported
    }
    func deleteScene(_ id: RoomScene.ID) async throws { throw TransportError.unsupported }

    func setRoomPower(_ on: Bool, room: Room) async throws {
        for id in room.lightIDs { try await setPower(on, for: id) }
    }
}

public enum TransportEvent: Sendable {
    /// A bulb appeared, or its metadata changed.
    case discovered(Light)
    /// The light reported a change. Partial by design — merge, do not substitute.
    case stateChanged(id: Light.ID, delta: LightStateDelta)
    case connectionChanged(id: Light.ID, connection: ConnectionState)
    /// Bluetooth permission / power state changed at the system level.
    case availabilityChanged(TransportAvailability)
}

public enum TransportAvailability: Sendable, Equatable {
    case ready
    case unauthorized
    case poweredOff
    case unsupported
    /// The bridge rejected our credentials — typically Vesta was removed from the
    /// bridge, so the stored key no longer exists. Distinct from `unauthorized`,
    /// which is macOS withholding Bluetooth permission.
    case credentialsRejected

    public var message: String? {
        switch self {
        case .ready:              nil
        case .unauthorized:       "Vesta needs Bluetooth access to find your lights."
        case .poweredOff:         "Bluetooth is turned off."
        case .unsupported:        "This Mac cannot use Bluetooth Low Energy."
        case .credentialsRejected:
            "The Bridge no longer recognises Vesta. Pair it again to reconnect."
        }
    }
}

public enum TransportError: LocalizedError, Equatable {
    case unknownLight
    case notConnected
    /// The bulb refused the write because there is no BLE bond.
    case needsPairing
    case writeFailed(String)
    case unsupported
    /// The bridge rejected our credentials — typically the app was removed
    /// from the bridge, so the stored key no longer exists.
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .unknownLight:      "That light is no longer available."
        case .notConnected:      "Not connected to that light."
        case .needsPairing:      "This light needs to be paired before Vesta can control it."
        case .writeFailed(let m): m
        case .unsupported:       "This isn’t available on the current connection."
        case .unauthorized:      "The Bridge no longer recognises Vesta. Pair it again."
        }
    }
}
