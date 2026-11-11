// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum KasaScheduleTime: Int, CaseIterable, Sendable {
    case clock = 0, sunrise = 1, sunset = 2
    public var title: String { switch self { case .clock: "Time"; case .sunrise: "Sunrise"; case .sunset: "Sunset" } }
}

/// Wall-clock components belong to the device, never converted through the Mac's zone.
public struct KasaScheduleDraft: Equatable, Sendable {
    public var name = ""
    public var enabled = true
    public var time: KasaScheduleTime = .clock
    public var minutes = 18 * 60
    public var offset = 0
    public var weekdays = [true, true, true, true, true, true, true] // Sunday first
    public var repeats = true
    public var year = 2026
    public var month = 1
    public var day = 1
    public var power = true
    public var brightness: Int?
    public init() {}

    public var isValid: Bool {
        (0..<1440).contains(minutes) && (-720...720).contains(offset)
            && weekdays.count == 7 && (!repeats || weekdays.contains(true))
            && (brightness == nil || (1...100).contains(brightness ?? 0))
            && name.utf8.count <= 64 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && (repeats || Self.validDate(year: year, month: month, day: day))
    }
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
    public static func validDate(year: Int, month: Int, day: Int) -> Bool {
        guard (2000...2099).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day
    }
    public var timeLabel: String {
        if time == .clock { return String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        return time.title + (offset == 0 ? "" : " \(offset > 0 ? "+" : "−")\(abs(offset)) min")
    }
    public var daysLabel: String {
        if !repeats { return String(format: "%04d-%02d-%02d", year, month, day) }
        if weekdays.allSatisfy({ $0 }) { return "Every day" }
        if weekdays == [false, true, true, true, true, true, false] { return "Weekdays" }
        if weekdays == [true, false, false, false, false, false, true] { return "Weekends" }
        return zip(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], weekdays)
            .filter { $0.1 }.map { $0.0 }.joined(separator: ", ")
    }
}

public struct KasaScheduleRule: Identifiable, Equatable, Sendable {
    public let id: String
    public let draft: KasaScheduleDraft
    public let editable: Bool
    /// Bounded canonical JSON retained only for lossless edits and conflict checks.
    /// The interface does not interpret it; unknown firmware fields survive writes.
    public let original: Data
    public init(id: String, draft: KasaScheduleDraft, editable: Bool, original: Data) {
        self.id = id; self.draft = draft; self.editable = editable; self.original = original
    }
}

public struct KasaDeviceClock: Equatable, Sendable {
    public let wallTime: Date
    public let sampledAt: Date
    public let zoneIndex: Int?
    public init(wallTime: Date, sampledAt: Date = Date(), zoneIndex: Int? = nil) {
        self.wallTime = wallTime; self.sampledAt = sampledAt; self.zoneIndex = zoneIndex
    }
    public var label: String {
        let parts = KasaScheduleDraft.calendar.dateComponents([.hour, .minute], from: wallTime)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    public func differsFromMac(timeZone: TimeZone = .current) -> Bool {
        let macWall = sampledAt.addingTimeInterval(Double(timeZone.secondsFromGMT(for: sampledAt)))
        return abs(wallTime.timeIntervalSince(macWall)) > 300
    }
}

public struct KasaScheduleState: Equatable, Sendable {
    public var rules: [KasaScheduleRule]
    public var enabled: Bool
    public var clock: KasaDeviceClock?
    public init(rules: [KasaScheduleRule], enabled: Bool, clock: KasaDeviceClock? = nil) {
        self.rules = rules; self.enabled = enabled; self.clock = clock
    }
}

public enum KasaScheduleChange: Sendable {
    case save(KasaScheduleDraft, replacing: KasaScheduleRule?)
    case enabled(KasaScheduleRule, Bool)
    case delete(KasaScheduleRule)
    case overallEnabled(Bool)
}

public enum KasaScheduleError: Error, LocalizedError, Sendable {
    case unsupported, invalid, conflict, unconfirmed
    public var errorDescription: String? {
        switch self {
        case .unsupported: "Schedules aren’t available for this device in Vesta Kasa."
        case .invalid: "Check the schedule time, date and repeat days."
        case .conflict: "This schedule changed in another app. Refresh and open it again before saving."
        case .unconfirmed: "The result couldn’t be confirmed. Refresh the schedules before trying again; the change may have reached the device."
        }
    }
}
