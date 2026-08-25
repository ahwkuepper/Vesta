import Foundation
import LumoKit

/// Turns the bridge's JSON into Lumo's model, with no network anywhere near it.
///
/// This lives apart from `BridgeTransport` so the decoding can be tested against
/// recorded responses. The bridge's *shape* is what has actually broken this app:
/// events arriving partial, rooms listing devices rather than lights, gradient point
/// counts, `status.active`. Those are contract details of somebody else's firmware,
/// they change without notice, and a fixture test catches the change in a second
/// rather than in someone's living room.
public enum BridgeCoding {

    // MARK: - Wire types

    struct ListResponse<T: Decodable>: Decodable { let data: [T] }

    struct LightResource: Decodable {
        struct Metadata: Decodable { let name: String? }
        struct On: Decodable { let on: Bool }
        struct Dimming: Decodable { let brightness: Double? }
        struct ColorTemperature: Decodable { let mirek: Int? }
        struct XY: Decodable { let x: Double; let y: Double }
        struct Color: Decodable { let xy: XY? }
        struct GradientInfo: Decodable { let points_capable: Int? }
        struct EffectAction: Decodable { let effect_values: [String]? }
        struct EffectsV2: Decodable { let action: EffectAction? }

        let id: String
        let type: String?
        let metadata: Metadata?
        let on: On?
        let dimming: Dimming?
        let color_temperature: ColorTemperature?
        let color: Color?
        let gradient: GradientInfo?
        let effects_v2: EffectsV2?
    }

    // MARK: - Lights

    public static func lights(from data: Data) throws -> [Light] {
        try JSONDecoder().decode(ListResponse<LightResource>.self, from: data)
            .data.compactMap(light(from:))
    }

    static func light(from resource: LightResource) -> Light? {
        guard let id = UUID(uuidString: resource.id) else { return nil }
        let effects = (resource.effects_v2?.action?.effect_values ?? [])
            .filter { $0 != "no_effect" }
        return Light(id: id,
                     name: resource.metadata?.name ?? "Light",
                     model: "Hue",
                     state: state(from: resource),
                     connection: .ready,
                     capabilities: LightCapabilities(
                        gradientPoints: resource.gradient?.points_capable,
                        effects: effects))
    }

    static func state(from resource: LightResource) -> LightState {
        var color = LightColor.temperature(mireds: 366)
        // Prefer colour temperature: the bridge keeps a stale xy around on
        // tunable-white bulbs, and reading it back would show the wrong swatch.
        if let mirek = resource.color_temperature?.mirek, mirek > 0 {
            color = .temperature(mireds: mirek)
        } else if let xy = resource.color?.xy {
            color = .xy(x: xy.x, y: xy.y)
        }
        return LightState(isOn: resource.on?.on ?? false,
                          brightness: (resource.dimming?.brightness ?? 50) / 100,
                          color: color)
    }

    /// Only the fields present in this payload. The bridge sends partial updates —
    /// a scene recall pushes colour with no `on` and no `dimming` — so defaulting
    /// the absent ones would report every light as off at 50%.
    static func delta(from resource: LightResource) -> LightStateDelta {
        var color: LightColor?
        if let mirek = resource.color_temperature?.mirek, mirek > 0 {
            color = .temperature(mireds: mirek)
        } else if let xy = resource.color?.xy {
            color = .xy(x: xy.x, y: xy.y)
        }
        return LightStateDelta(
            isOn: resource.on?.on,
            brightness: resource.dimming?.brightness.map { $0 / 100 },
            color: color)
    }

    /// Server-sent event payload → the deltas it actually carries.
    public static func deltas(fromEvent data: Data) -> [(id: Light.ID, delta: LightStateDelta)] {
        guard let events = try? JSONDecoder().decode([ListResponse<LightResource>].self,
                                                     from: data) else { return [] }
        return events.flatMap(\.data).compactMap { resource in
            guard resource.type == "light", let id = UUID(uuidString: resource.id) else {
                return nil
            }
            let delta = delta(from: resource)
            // An event mentioning nothing we model must not become a state change.
            return delta.isEmpty ? nil : (id, delta)
        }
    }

    // MARK: - Rooms

    /// Rooms list *devices*, not lights, so the device list is needed to map each
    /// one to the light service it exposes.
    public static func rooms(from roomsData: Data, devices devicesData: Data) throws -> [Room] {
        let rooms = try objects(in: roomsData)
        let devices = try objects(in: devicesData)

        var lightForDevice: [String: UUID] = [:]
        for device in devices {
            guard let id = device["id"] as? String,
                  let services = device["services"] as? [[String: Any]] else { continue }
            if let light = services.first(where: { $0["rtype"] as? String == "light" }),
               let rid = light["rid"] as? String, let uuid = UUID(uuidString: rid) {
                lightForDevice[id] = uuid
            }
        }

        return rooms.compactMap { room in
            guard let idString = room["id"] as? String, let id = UUID(uuidString: idString),
                  let metadata = room["metadata"] as? [String: Any],
                  let name = metadata["name"] as? String else { return nil }

            let children = (room["children"] as? [[String: Any]]) ?? []
            let lightIDs = children.compactMap { child -> UUID? in
                guard let rid = child["rid"] as? String else { return nil }
                return lightForDevice[rid]
            }

            let services = (room["services"] as? [[String: Any]]) ?? []
            let grouped = services
                .first { $0["rtype"] as? String == "grouped_light" }
                .flatMap { $0["rid"] as? String }
                .flatMap(UUID.init(uuidString:))

            return Room(id: id, name: name,
                        archetype: metadata["archetype"] as? String ?? "other",
                        lightIDs: lightIDs, groupedLightID: grouped)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Scenes

    public static func scenes(from data: Data, appTag: String) throws -> [RoomScene] {
        try objects(in: data).compactMap { scene in
            guard let idString = scene["id"] as? String, let id = UUID(uuidString: idString),
                  let metadata = scene["metadata"] as? [String: Any],
                  let name = metadata["name"] as? String,
                  let group = scene["group"] as? [String: Any],
                  group["rtype"] as? String == "room",
                  let rid = group["rid"] as? String, let roomID = UUID(uuidString: rid)
            else { return nil }

            // Only scenes Lumo created are offered for deletion — a scene built in
            // the Hue app may be shared with routines and switches.
            let isEditable = (metadata["appdata"] as? String)?.hasPrefix(appTag) ?? false
            // "inactive" | "static" | "dynamic_palette" — anything but inactive means
            // the room currently matches this scene.
            let active = ((scene["status"] as? [String: Any])?["active"] as? String) ?? "inactive"
            return RoomScene(id: id, name: name, roomID: roomID,
                             isEditable: isEditable, isActive: active != "inactive",
                             tint: representativeColour(of: scene))
        }
        .sorted { $0.name < $1.name }
    }

    /// The colour a scene chip should carry: the first lit light the scene sets.
    ///
    /// Read from the scene's own actions, so "Candlelight" is warm because the scene
    /// is warm.
    ///
    /// A scene can set several lights to different colours and one chip cannot show
    /// that, so this takes the first rather than averaging, which would muddy them.
    public static func representativeColour(of scene: [String: Any]) -> LightColor? {
        guard let actions = scene["actions"] as? [[String: Any]] else { return nil }
        for entry in actions {
            guard let action = entry["action"] as? [String: Any] else { continue }
            // A light the scene switches off contributes no colour.
            if let on = action["on"] as? [String: Any], on["on"] as? Bool == false {
                continue
            }
            if let mirek = (action["color_temperature"] as? [String: Any])?["mirek"] as? Int,
               mirek > 0 {
                return .temperature(mireds: mirek)
            }
            if let xy = (action["color"] as? [String: Any])?["xy"] as? [String: Any],
               let x = xy["x"] as? Double, let y = xy["y"] as? Double {
                return .xy(x: x, y: y)
            }
            if let points = (action["gradient"] as? [String: Any])?["points"] as? [[String: Any]],
               let first = points.first,
               let xy = (first["color"] as? [String: Any])?["xy"] as? [String: Any],
               let x = xy["x"] as? Double, let y = xy["y"] as? Double {
                return .xy(x: x, y: y)
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func objects(in data: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw BridgeError.malformedResponse
        }
        return list
    }
}
