// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import KasaKit

/// Keeps schedule commands scoped to one module and, for strips, one outlet.
/// No bulk deletion, timezone changes, or immediate relay commands are exposed.
enum KasaScheduleCoding {
    static func module(_ device: KasaDevice) -> String {
        device.isBulb ? "smartlife.iot.common.schedule" : "schedule"
    }
    static func timeModule(_ device: KasaDevice) -> String {
        device.isBulb ? "smartlife.iot.common.timesetting" : "time"
    }
    static func request(_ method: String, payload: [String: Any] = [:], device: KasaDevice, clock: Bool = false) throws -> Data {
        var root: [String: Any] = [module(device): [method: payload]]
        if clock { root[timeModule(device)] = ["get_time": [:], "get_timezone": [:]] }
        if let child = device.childID { root["context"] = ["child_ids": [child]] }
        return try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
    }
    static func result(_ response: [String: Any], method: String, device: KasaDevice) throws -> [String: Any] {
        guard let module = response[module(device)] as? [String: Any] else { throw KasaError.invalidResponse }
        if KasaCoding.integer(module["err_code"], in: -100_000...100_000) == -1 { throw KasaScheduleError.unsupported }
        guard let result = module[method] as? [String: Any],
              let code = KasaCoding.integer(result["err_code"], in: -100_000...100_000) else { throw KasaError.invalidResponse }
        if code == -1 { throw KasaScheduleError.unsupported }
        guard code == 0 else { throw KasaError.rejected(code) }
        return result
    }
    static func decode(_ response: [String: Any], device: KasaDevice) throws -> KasaScheduleState {
        let result = try result(response, method: "get_rules", device: device)
        guard let list = result["rule_list"] as? [[String: Any]], list.count <= 128,
              let enabled = KasaCoding.integer(result["enable"], in: 0...1) else { throw KasaError.invalidResponse }
        let rules = try list.map { try rule($0, device: device) }
        guard Set(rules.map(\.id)).count == rules.count else { throw KasaError.invalidResponse }
        return KasaScheduleState(rules: rules, enabled: enabled == 1, clock: clock(response, device: device))
    }
    static func rule(_ raw: [String: Any], device: KasaDevice) throws -> KasaScheduleRule {
        guard let id = raw["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let enabled = KasaCoding.integer(raw["enable"], in: 0...1) else { throw KasaError.invalidResponse }
        var draft = KasaScheduleDraft()
        draft.name = KasaCoding.text(raw["name"], limit: 64)
        draft.enabled = enabled == 1
        let kind = KasaCoding.integer(raw["stime_opt"], in: 0...2).flatMap(KasaScheduleTime.init(rawValue:))
        draft.time = kind ?? .clock
        let minutes = KasaCoding.integer(raw["smin"], in: 0...1439)
        draft.minutes = minutes ?? 0
        let offset = KasaCoding.integer(raw["soffset"] ?? 0, in: -720...720)
        draft.offset = offset ?? 0
        let days = (raw["wday"] as? [Any])?.compactMap { KasaCoding.integer($0, in: 0...1) }
        draft.weekdays = days?.count == 7 ? (days ?? []).map { $0 == 1 } : Array(repeating: false, count: 7)
        let repeats = KasaCoding.integer(raw["repeat"], in: 0...1)
        draft.repeats = repeats == 1
        draft.year = KasaCoding.integer(raw["year"], in: 2000...2099) ?? 0
        draft.month = KasaCoding.integer(raw["month"], in: 1...12) ?? 0
        draft.day = KasaCoding.integer(raw["day"], in: 1...31) ?? 0
        let action = KasaCoding.integer(raw["sact"], in: 0...3)
        let light = raw["s_light"] as? [String: Any]
        let power = device.isBulb && action == 2 ? KasaCoding.integer(light?["on_off"], in: 0...1)
            : KasaCoding.integer(raw["sact"], in: 0...1)
        draft.power = power == 1
        draft.brightness = KasaCoding.integer(light?["brightness"], in: 1...100)
        let hasNoEnd = KasaCoding.integer(raw["etime_opt"] ?? -1, in: -1...2) == -1
        let editable = kind != nil && (kind != .clock || minutes != nil) && offset != nil
            && days?.count == 7 && repeats != nil && power != nil && hasNoEnd && draft.isValid
        let data = try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys)
        guard data.count <= 16_384 else { throw KasaError.invalidResponse }
        return KasaScheduleRule(id: id, draft: draft, editable: editable, original: data)
    }
    static func clock(_ response: [String: Any], device: KasaDevice) -> KasaDeviceClock? {
        guard let module = response[timeModule(device)] as? [String: Any],
              let time = module["get_time"] as? [String: Any],
              KasaCoding.integer(time["err_code"], in: -100_000...100_000) == 0,
              let year = KasaCoding.integer(time["year"], in: 2000...2099),
              let month = KasaCoding.integer(time["month"], in: 1...12),
              let day = KasaCoding.integer(time["mday"], in: 1...31),
              KasaScheduleDraft.validDate(year: year, month: month, day: day),
              let hour = KasaCoding.integer(time["hour"], in: 0...23),
              let minute = KasaCoding.integer(time["min"], in: 0...59),
              let second = KasaCoding.integer(time["sec"], in: 0...59),
              let date = KasaScheduleDraft.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { return nil }
        let zone = module["get_timezone"] as? [String: Any]
        return KasaDeviceClock(wallTime: date, zoneIndex: KasaCoding.integer(zone?["index"], in: 0...512))
    }

    static func mutation(_ change: KasaScheduleChange, current: KasaScheduleState, device: KasaDevice) throws -> (method: String, payload: [String: Any]) {
        func existing(_ rule: KasaScheduleRule) throws -> [String: Any] {
            guard let fresh = current.rules.first(where: { $0.id == rule.id }), fresh.original == rule.original else {
                throw KasaScheduleError.conflict
            }
            return try KasaCoding.object(fresh.original)
        }
        switch change {
        case .overallEnabled(let enabled): return ("set_overall_enable", ["enable": enabled ? 1 : 0])
        case .delete(let rule):
            _ = try existing(rule)
            return ("delete_rule", ["id": rule.id])
        case .enabled(let rule, let enabled):
            var raw = try existing(rule); raw["enable"] = enabled ? 1 : 0
            return ("edit_rule", raw)
        case .save(let draft, let previous):
            guard draft.isValid, previous?.editable != false else { throw KasaScheduleError.invalid }
            var raw = try previous.map(existing) ?? ["emin": device.isBulb ? -1 : 0, "etime_opt": -1]
            // Preserve fields not represented by this editor, including saved bulb
            // colour, transition settings, firmware metadata, and end-action flags.
            raw["name"] = draft.name; raw["enable"] = draft.enabled ? 1 : 0
            raw["stime_opt"] = draft.time.rawValue; raw["smin"] = draft.time == .clock ? draft.minutes : 0
            raw["soffset"] = draft.time == .clock ? 0 : draft.offset
            raw["repeat"] = draft.repeats ? 1 : 0
            raw["wday"] = draft.weekdays.map { $0 ? 1 : 0 }
            raw["year"] = draft.repeats ? 0 : draft.year
            raw["month"] = draft.repeats ? 0 : draft.month
            raw["day"] = draft.repeats ? 0 : draft.day
            if !draft.repeats, let date = KasaScheduleDraft.calendar.date(from: DateComponents(year: draft.year, month: draft.month, day: draft.day)) {
                let weekday = KasaScheduleDraft.calendar.component(.weekday, from: date) - 1
                raw["wday"] = (0..<7).map { $0 == weekday ? 1 : 0 }
            }
            if device.isBulb {
                var light = raw["s_light"] as? [String: Any] ?? ["ignore_default": 0]
                raw["sact"] = 2; light["on_off"] = draft.power ? 1 : 0
                if let brightness = draft.brightness {
                    guard device.brightness != nil else { throw KasaScheduleError.invalid }
                    light["brightness"] = brightness
                    light["ignore_default"] = 1
                } else {
                    light.removeValue(forKey: "brightness")
                    if light["color_temp"] == nil && light["hue"] == nil && light["saturation"] == nil {
                        light["ignore_default"] = 0
                    }
                }
                raw["s_light"] = light
            } else { raw["sact"] = draft.power ? 1 : 0 }
            return (previous == nil ? "add_rule" : "edit_rule", raw)
        }
    }
    static func confirmed(_ change: KasaScheduleChange, after: KasaScheduleState, addedID: String?, device: KasaDevice) -> Bool {
        switch change {
        case .overallEnabled(let enabled): return after.enabled == enabled
        case .delete(let rule): return !after.rules.contains { $0.id == rule.id }
        case .enabled(let rule, let enabled): return after.rules.first { $0.id == rule.id }?.draft.enabled == enabled
        case .save(let expected, let previous):
            guard let id = previous?.id ?? addedID,
                  let actual = after.rules.first(where: { $0.id == id })?.draft else { return false }
            return actual.name == expected.name && actual.enabled == expected.enabled
                && actual.time == expected.time && actual.power == expected.power
                && actual.repeats == expected.repeats
                && (expected.time == .clock ? actual.minutes == expected.minutes : actual.offset == expected.offset)
                && (expected.repeats ? actual.weekdays == expected.weekdays
                    : actual.year == expected.year && actual.month == expected.month && actual.day == expected.day)
                && (!device.isBulb || actual.brightness == expected.brightness)
        }
    }

}
