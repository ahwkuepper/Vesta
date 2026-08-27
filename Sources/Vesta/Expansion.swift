import Foundation
import VestaKit

/// Which lights currently have their controls open.
///
/// Several lights in the *same* room stay open together: adjusting two lamps in one
/// room to match is a common thing to do, and it needs both sets of controls visible
/// at once. Opening a light in a *different* room closes the others, because
/// comparing settings across rooms is rarely the point and the popover would grow
/// without limit.
struct Expansion: Equatable {
    /// The room whose lights are currently open. `nil` covers lights with no room.
    private(set) var roomID: Room.ID?
    private(set) var ids: Set<Light.ID> = []

    func isExpanded(_ id: Light.ID) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: Light.ID, in room: Room.ID?) {
        if room != roomID {
            roomID = room
            ids = []
        }
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    mutating func open(_ id: Light.ID, in room: Room.ID?) {
        if room != roomID { roomID = room; ids = [] }
        ids.insert(id)
    }
}
