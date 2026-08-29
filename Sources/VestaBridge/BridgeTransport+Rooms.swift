// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import VestaKit

/// Rooms and scenes, which exist only on a bridge.
///
/// Both are read from the bridge rather than invented locally, so Vesta, the Hue app
/// and any wall switch all agree. A scene saved here is a real Hue scene and shows
/// up in the Hue app immediately.
extension BridgeTransport {

    // MARK: - Rooms

    public func fetchRooms() async throws -> [Room] {
        async let roomsData = rawData(for: "room")
        async let devicesData = rawData(for: "device")
        return try await BridgeCoding.rooms(from: roomsData, devices: devicesData)
    }

    /// One request for the whole room. Setting each bulb in turn makes the room
    /// visibly ripple on rather than switch on.
    public func setRoomPower(_ on: Bool, room: Room) async throws {
        guard let grouped = room.groupedLightID else {
            for id in room.lightIDs { try await setPower(on, for: id) }
            return
        }
        try await put(["on": ["on": on]], to: "grouped_light/\(grouped.uuidString.lowercased())")
    }

    public func setRoomBrightness(_ brightness: Double, room: Room) async throws {
        guard let grouped = room.groupedLightID else {
            for id in room.lightIDs { try await setBrightness(brightness, for: id) }
            return
        }
        let percent = max(1.0, min(100.0, brightness * 100))
        try await put(["dimming": ["brightness": percent]],
                      to: "grouped_light/\(grouped.uuidString.lowercased())")
    }

    // MARK: - Scenes

    public func fetchScenes() async throws -> [RoomScene] {
        try BridgeCoding.scenes(from: await rawData(for: "scene"), appTag: Self.appTag)
    }

    /// Marks scenes Vesta created, so they can be safely offered for deletion.
    static let appTag = "vesta"

    public func recallScene(_ id: RoomScene.ID) async throws {
        try await put(["recall": ["action": "active"]],
                      to: "scene/\(id.uuidString.lowercased())")
    }

    /// Captures every light in the room at its current state as a real Hue scene.
    public func createScene(named name: String, in room: Room.ID,
                            actions requested: [SceneAction] = []) async throws -> RoomScene {
        let rooms = try await fetchRooms()
        guard let target = rooms.first(where: { $0.id == room }) else {
            throw BridgeError.malformedResponse
        }
        let lights = try await fetchLights()

        // An empty request means "save what the room is doing right now".
        let plan: [SceneAction] = requested.isEmpty
            ? target.lightIDs.compactMap { id in
                lights.first { $0.id == id }.map { SceneAction(lightID: $0.id, state: $0.state) }
              }
            : requested

        let actions: [[String: Any]] = plan.map { item in
            var action: [String: Any] = ["on": ["on": item.state.isOn]]
            // A scene that only stores which lights are on is not a scene; capture
            // brightness and colour too — but only for lights that are on, since the
            // bridge rejects dimming values on a light being turned off.
            if item.state.isOn {
                action["dimming"] = ["brightness": max(1.0, item.state.brightness * 100)]
                switch item.state.color {
                case .temperature(let mireds):
                    action["color_temperature"] = ["mirek": mireds]
                case .xy(let x, let y):
                    action["color"] = ["xy": ["x": x, "y": y]]
                }
                if let gradient = item.gradient {
                    action["gradient"] = ["points": gradient.points.map { color -> [String: Any] in
                        let xy: (x: Double, y: Double)
                        switch color {
                        case .xy(let x, let y): xy = (x, y)
                        case .temperature(let m):
                            xy = ColorScience.xy(fromRGB: ColorScience.rgb(fromMireds: m))
                        }
                        return ["color": ["xy": ["x": xy.x, "y": xy.y]]]
                    }, "mode": gradient.mode]
                }
            }
            return ["target": ["rid": item.lightID.uuidString.lowercased(), "rtype": "light"],
                    "action": action]
        }

        guard !actions.isEmpty else { throw BridgeError.malformedResponse }

        let body: [String: Any] = [
            "type": "scene",
            "metadata": ["name": String(name.prefix(32)), "appdata": Self.appTag],
            "group": ["rid": room.uuidString.lowercased(), "rtype": "room"],
            "actions": actions,
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await send(
            request(try resource("scene"), method: "POST", body: data))

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: responseData, encoding: .utf8) ?? ""
            throw BridgeError.http((response as? HTTPURLResponse)?.statusCode ?? -1, text)
        }
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let created = (object["data"] as? [[String: Any]])?.first,
              let rid = created["rid"] as? String, let id = UUID(uuidString: rid)
        else { throw BridgeError.malformedResponse }

        return RoomScene(id: id, name: name, roomID: room, isEditable: true)
    }

    public func deleteScene(_ id: RoomScene.ID) async throws {
        let url = try resource("scene/\(id.uuidString.lowercased())")
        let (data, response) = try await send(request(url, method: "DELETE"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.http((response as? HTTPURLResponse)?.statusCode ?? -1,
                                   String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Helpers

    private func rawData(for type: String) async throws -> Data {
        let (data, response) = try await send(request(try resource(type)))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.http((response as? HTTPURLResponse)?.statusCode ?? -1,
                                   String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func json(for type: String) async throws -> [[String: Any]] {
        try BridgeCoding.objects(in: await rawData(for: type))
    }

    func put(_ body: [String: Any], to path: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await send(
            request(try resource(path), method: "PUT", body: data))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.http((response as? HTTPURLResponse)?.statusCode ?? -1,
                                   String(data: responseData, encoding: .utf8) ?? "")
        }
    }
}
