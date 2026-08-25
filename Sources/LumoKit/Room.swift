import Foundation

/// A room as the bridge defines it. Rooms live on the bridge, shared with the Hue
/// app and any other controller — Lumo reads them rather than inventing its own
/// grouping, so the two never disagree.
public struct Room: Identifiable, Sendable, Equatable {
    public typealias ID = UUID

    public let id: ID
    public var name: String
    /// Hue archetype (`office`, `living_room`, …), used to pick an icon.
    public var archetype: String
    public var lightIDs: [Light.ID]
    /// The bridge's `grouped_light` service: one call sets the whole room, instead
    /// of N calls that visibly ripple across the bulbs.
    public var groupedLightID: UUID?

    public init(id: ID, name: String, archetype: String = "other",
                lightIDs: [Light.ID] = [], groupedLightID: UUID? = nil) {
        self.id = id
        self.name = name
        self.archetype = archetype
        self.lightIDs = lightIDs
        self.groupedLightID = groupedLightID
    }

    /// SF Symbol for the room's archetype.
    public var symbol: String {
        switch archetype {
        case "living_room", "lounge":      "sofa.fill"
        case "kitchen":                    "refrigerator.fill"
        case "dining":                     "fork.knife"
        case "bedroom", "kids_bedroom":    "bed.double.fill"
        case "bathroom", "toilet":         "shower.fill"
        case "office", "computer", "study": "desktopcomputer"
        case "garage", "carport":          "car.fill"
        case "garden", "terrace", "balcony", "driveway": "tree.fill"
        case "hallway", "staircase":       "figure.walk"
        case "gym":                        "dumbbell.fill"
        case "nursery":                    "figure.and.child.holdinghands"
        default:                           "lightbulb.2.fill"
        }
    }
}

/// A scene stored on the bridge, scoped to one room.
///
/// These are the same scenes the Hue app shows, so anything saved here appears
/// there and vice versa. Recalling one is a single request — the bridge applies
/// every light, including effects like gradients that Lumo does not model.
public struct RoomScene: Identifiable, Sendable, Equatable {
    public typealias ID = UUID

    public let id: ID
    public var name: String
    public var roomID: Room.ID
    /// Set when Lumo created it, so the UI can offer deletion without risking a
    /// scene the user built in the Hue app.
    public var isEditable: Bool

    /// The bridge's own view of whether this scene is what the room is currently
    /// doing. Reported as `status.active`, and it goes back to inactive the moment
    /// any light in the room is changed — so it answers "are my current settings a
    /// scene?", not merely "which scene did I last press".
    public var isActive: Bool
    /// A colour the scene actually sets, taken from its stored actions.
    ///
    /// `nil` when the scene turns everything off, or when the bridge did not report
    /// usable actions. Nothing is invented in that case: a chip with no known colour
    /// is drawn untinted rather than given a decorative one.
    public var tint: LightColor?

    public init(id: ID, name: String, roomID: Room.ID, isEditable: Bool = false,
                isActive: Bool = false, tint: LightColor? = nil) {
        self.id = id
        self.name = name
        self.roomID = roomID
        self.isEditable = isEditable
        self.isActive = isActive
        self.tint = tint
    }
}


/// One light's contribution to a scene. Presets specify these directly; "save the
/// current look" leaves the list empty and lets the transport capture what is live.
public struct SceneAction: Sendable, Equatable {
    public var lightID: Light.ID
    public var state: LightState
    /// Set for gradient fixtures, so a preset pins the whole strip rather than
    /// leaving whatever gradient happened to be active.
    public var gradient: LightGradient?

    public init(lightID: Light.ID, state: LightState, gradient: LightGradient? = nil) {
        self.lightID = lightID
        self.state = state
        self.gradient = gradient
    }
}
