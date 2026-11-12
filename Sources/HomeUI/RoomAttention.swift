import Foundation

enum RoomPriority: String, Codable, CaseIterable {
    case automatic = "Automatic", normal = "Normal priority", low = "Keep low"
}
enum DeviceAttention: String, Codable, CaseIterable {
    case automatic = "Automatic", everyday = "Everyday", background = "Background"
}

/// A compact local summary, not an activity log. Polls and scheduled changes never
/// enter this model. Repeated slider updates count as one use within a minute.
struct RoomUse: Codable, Equatable {
    var lastUsed: Date
    var lastCounted: Date
    var frequency: Double

    func strength(at now: Date) -> Double {
        frequency * pow(0.5, max(0, now.timeIntervalSince(lastCounted)) / (14 * 86400))
    }
    mutating func record(at now: Date) {
        if now.timeIntervalSince(lastCounted) >= 60 {
            frequency = min(100, strength(at: now) + 1); lastCounted = now
        }
        lastUsed = now
    }
    func valid(at now: Date) -> Bool {
        frequency.isFinite && (0...100).contains(frequency)
            && lastUsed.timeIntervalSinceReferenceDate.isFinite
            && lastCounted.timeIntervalSinceReferenceDate.isFinite
            && lastUsed <= now.addingTimeInterval(300) && lastCounted <= lastUsed
    }
}

enum RoomAttention {
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
    }
    static func suggestsBackgroundDevice(_ name: String) -> Bool {
        !words(name).isDisjoint(with: ["charger", "charging", "christmas", "xmas", "halloween", "holiday", "seasonal", "decorations", "decoration"])
    }
    static func suggestsBackgroundRoom(_ name: String) -> Bool {
        !words(name).isDisjoint(with: ["garage", "storage"])
    }
    static func isBackground(_ device: HomeDevice, placement: DevicePlacement?) -> Bool {
        switch placement?.attention ?? .automatic {
        case .everyday: false
        case .background: true
        case .automatic: suggestsBackgroundDevice(device.name)
        }
    }
    static func isLow(_ room: String, priority: RoomPriority, use: RoomUse?, at now: Date) -> Bool {
        switch priority {
        case .low: true
        case .normal: false
        case .automatic:
            // Utility rooms start low. Repeated deliberate use can overcome this
            // weak prior; an explicit Keep low choice always wins.
            suggestsBackgroundRoom(room) && (use?.strength(at: now) ?? 0) < 3
        }
    }
    static func sorted(rooms: [String], devices: [HomeDevice], placements: [String: DevicePlacement],
                       priorities: [String: RoomPriority], uses: [String: RoomUse], at now: Date) -> [String] {
        let active = Set(devices.filter {
            $0.kind == .light && $0.isOn && $0.reachable && !isBackground($0, placement: placements[$0.id])
        }.map(\.room))
        func tier(_ room: String) -> Int {
            if room == "Unassigned" { return 3 }
            if isLow(room, priority: priorities[room] ?? .automatic, use: uses[room], at: now) { return 2 }
            return active.contains(room) ? 0 : 1
        }
        func recent(_ room: String) -> Date {
            guard let use = uses[room], now.timeIntervalSince(use.lastUsed) <= 30 * 86400 else { return .distantPast }
            return use.lastUsed
        }
        return rooms.sorted {
            if tier($0) != tier($1) { return tier($0) < tier($1) }
            if recent($0) != recent($1) { return recent($0) > recent($1) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}
