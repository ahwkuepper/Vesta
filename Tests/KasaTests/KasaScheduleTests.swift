// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import KasaKit
@testable import KasaTransport
@testable import KasaUI

@Suite("Kasa device schedules")
struct KasaScheduleTests {
    private let bulb = KasaDevice(id: "fixture", host: "192.0.2.1", name: "Fixture", model: "KL110", isBulb: true, brightness: 70)
    private let plug = KasaDevice(id: "outlet", host: "192.0.2.2", name: "Outlet", model: "HS300", childID: "child-2")
    private func raw(bulb: Bool = true) -> [String: Any] {
        var rule: [String: Any] = ["id": "rule-1", "name": "Evening", "enable": 1, "stime_opt": 2,
            "smin": 1100, "soffset": -15, "repeat": 1, "wday": [1,1,1,1,1,1,1],
            "year": 0, "month": 0, "day": 0, "etime_opt": -1, "emin": 0, "sact": bulb ? 2 : 1,
            "firmware_extra": ["keep": 42]]
        if bulb { rule["s_light"] = ["on_off": 1, "brightness": 70, "color_temp": 3000,
                                    "hue": 20, "saturation": 10, "transition_period": 750, "ignore_default": 1] }
        return rule
    }
    private func state(_ raw: [String: Any], device: KasaDevice) throws -> KasaScheduleState {
        try KasaScheduleCoding.decode([KasaScheduleCoding.module(device): ["get_rules": ["err_code": 0, "enable": 1, "rule_list": [raw]]]], device: device)
    }

    @Test("Bulb schedules decode sun offsets, repeat days and saved light state")
    func decode() throws {
        let state = try state(raw(), device: bulb)
        let rule = try #require(state.rules.first)
        #expect(rule.editable)
        #expect(rule.draft.time == .sunset)
        #expect(rule.draft.offset == -15)
        #expect(rule.draft.brightness == 70)
        #expect(rule.draft.daysLabel == "Every day")
        #expect(rule.draft.timeLabel == "Sunset −15 min")
    }

    @Test("Editing a bulb preserves colour, transitions and unknown firmware fields")
    func preserve() throws {
        let state = try state(raw(), device: bulb)
        let rule = try #require(state.rules.first)
        var edit = rule.draft; edit.time = .clock; edit.minutes = 20 * 60; edit.brightness = 50
        let mutation = try KasaScheduleCoding.mutation(.save(edit, replacing: rule), current: state, device: bulb)
        #expect(mutation.method == "edit_rule")
        let light = try #require(mutation.payload["s_light"] as? [String: Int])
        #expect(light["color_temp"] == 3000)
        #expect(light["hue"] == 20)
        #expect(light["transition_period"] == 750)
        #expect(light["brightness"] == 50)
        #expect((mutation.payload["firmware_extra"] as? [String: Int])?["keep"] == 42)
        #expect(mutation.payload["smin"] as? Int == 1200)
        #expect(mutation.payload["soffset"] as? Int == 0)
    }

    @Test("Disabling scheduled brightness removes its override without losing colour")
    func removeBrightness() throws {
        let state = try state(raw(), device: bulb)
        let rule = try #require(state.rules.first)
        var edit = rule.draft; edit.brightness = nil
        let mutation = try KasaScheduleCoding.mutation(.save(edit, replacing: rule), current: state, device: bulb)
        let light = try #require(mutation.payload["s_light"] as? [String: Any])
        #expect(light["brightness"] == nil)
        #expect(light["color_temp"] as? Int == 3000)
    }

    @Test("Enable changes only one field, and strip schedules address one outlet")
    func scope() throws {
        let state = try state(raw(bulb: false), device: plug)
        let rule = try #require(state.rules.first)
        let mutation = try KasaScheduleCoding.mutation(.enabled(rule, false), current: state, device: plug)
        var expected = raw(bulb: false); expected["enable"] = 0
        #expect(NSDictionary(dictionary: mutation.payload).isEqual(to: expected))
        let request = try KasaCoding.object(KasaScheduleCoding.request(mutation.method, payload: mutation.payload, device: plug))
        #expect(Set(request.keys) == ["schedule", "context"])
        #expect((request["context"] as? [String: [String]])?["child_ids"] == ["child-2"])
        #expect(request["system"] == nil)
    }

    @Test("Concurrent edits from Kasa cause a conflict rather than an overwrite")
    func conflict() throws {
        let old = try state(raw(), device: bulb)
        let rule = try #require(old.rules.first)
        var changed = raw(); changed["soffset"] = 30
        let fresh = try state(changed, device: bulb)
        #expect(throws: KasaScheduleError.self) {
            try KasaScheduleCoding.mutation(.save(rule.draft, replacing: rule), current: fresh, device: bulb)
        }
        #expect(throws: KasaScheduleError.self) {
            try KasaScheduleCoding.mutation(.delete(rule), current: fresh, device: bulb)
        }
    }

    @Test("Advanced rules remain visible and can be disabled without reinterpreting them")
    func advanced() throws {
        var advanced = raw(); advanced["etime_opt"] = 0; advanced["emin"] = 1200
        let state = try state(advanced, device: bulb)
        let rule = try #require(state.rules.first)
        #expect(!rule.editable)
        #expect(throws: KasaScheduleError.self) {
            try KasaScheduleCoding.mutation(.save(rule.draft, replacing: rule), current: state, device: bulb)
        }
        let mutation = try KasaScheduleCoding.mutation(.enabled(rule, false), current: state, device: bulb)
        #expect(mutation.payload["etime_opt"] as? Int == 0)
        #expect(mutation.payload["emin"] as? Int == 1200)
    }

    @Test("Malformed lists and duplicate identities cannot silently replace schedules")
    func malformed() throws {
        let module = KasaScheduleCoding.module(bulb)
        for value in [[], [raw(), raw()], Array(repeating: raw(), count: 129)] as [[[String: Any]]] {
            let response: [String: Any] = [module: ["get_rules": ["err_code": 0, "rule_list": value]]]
            #expect(throws: (any Error).self) { try KasaScheduleCoding.decode(response, device: bulb) }
        }
        let duplicate: [String: Any] = [module: ["get_rules": ["err_code": 0, "enable": 1, "rule_list": [raw(), raw()]]]]
        #expect(throws: (any Error).self) { try KasaScheduleCoding.decode(duplicate, device: bulb) }
        let unsupported: [String: Any] = [module: ["err_code": -1]]
        #expect(throws: KasaScheduleError.self) { try KasaScheduleCoding.decode(unsupported, device: bulb) }
    }

    @Test("Only valid dates and weekly selections can be saved")
    func validation() throws {
        var draft = KasaScheduleDraft(); draft.weekdays = Array(repeating: false, count: 7)
        #expect(!draft.isValid)
        draft.repeats = false; draft.year = 2028; draft.month = 2; draft.day = 29
        #expect(draft.isValid)
        let mutation = try KasaScheduleCoding.mutation(.save(draft, replacing: nil), current: .init(rules: [], enabled: true), device: plug)
        #expect(mutation.method == "add_rule")
        #expect(mutation.payload["wday"] as? [Int] == [0,0,1,0,0,0,0])
        draft.year = 2027
        #expect(!draft.isValid)
        #expect(throws: KasaScheduleError.self) {
            try KasaScheduleCoding.mutation(.save(draft, replacing: nil), current: .init(rules: [], enabled: true), device: plug)
        }
    }

    @Test("Device clock comparison includes the date and does not reinterpret wall time")
    func clock() throws {
        let now = try #require(KasaScheduleDraft.calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 18)))
        let zone = try #require(TimeZone(secondsFromGMT: -7 * 3600))
        let clock = KasaDeviceClock(wallTime: now.addingTimeInterval(-7 * 3600), sampledAt: now)
        #expect(clock.label == "11:00")
        #expect(!clock.differsFromMac(timeZone: zone))
        #expect(KasaDeviceClock(wallTime: clock.wallTime.addingTimeInterval(3600), sampledAt: now).differsFromMac(timeZone: zone))
        #expect(KasaDeviceClock(wallTime: clock.wallTime.addingTimeInterval(-86400), sampledAt: now).differsFromMac(timeZone: zone))
    }

    @Test("An acknowledgement alone cannot confirm a schedule mutation")
    func readback() throws {
        let before = try state(raw(), device: bulb)
        let rule = try #require(before.rules.first)
        #expect(!KasaScheduleCoding.confirmed(.enabled(rule, false), after: before, addedID: nil, device: bulb))
        #expect(!KasaScheduleCoding.confirmed(.delete(rule), after: before, addedID: nil, device: bulb))
        var edit = rule.draft; edit.minutes = 900; edit.time = .clock
        #expect(!KasaScheduleCoding.confirmed(.save(edit, replacing: rule), after: before, addedID: nil, device: bulb))
        #expect(!KasaScheduleCoding.confirmed(.save(rule.draft, replacing: nil), after: before, addedID: nil, device: bulb))
        #expect(KasaScheduleCoding.confirmed(.save(rule.draft, replacing: nil), after: before, addedID: rule.id, device: bulb))
    }
}

private actor ScheduleFailureService: KasaServing {
    var writes = 0
    func discover() async throws -> [KasaDevice] { [] }
    func read(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> [KasaDevice] { [device] }
    func apply(_ command: KasaCommand, to device: KasaDevice, credentials: KasaCredentials?) async throws {}
    func schedules(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState { .init(rules: [], enabled: true) }
    func changeSchedule(_ change: KasaScheduleChange, device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState {
        writes += 1
        throw KasaScheduleError.unconfirmed
    }
}

@Suite("Schedule editor state")
@MainActor
struct KasaScheduleModelTests {
    @Test("Opening and cancelling an editor leaves device schedules untouched")
    func cancel() async throws {
        let model = KasaModel(demo: true)
        let device = try #require(model.devices.first)
        await model.loadSchedules(for: device)
        let before = model.scheduleStates[device.id]
        model.beginScheduleEdit(for: device)
        model.scheduleEdits[device.id]?.draft.minutes = 700
        model.scheduleEdits[device.id] = nil
        #expect(model.scheduleStates[device.id] == before)
    }

    @Test("Saving applies only to the selected device and survives a panel reload")
    func scopedSave() async throws {
        let model = KasaModel(demo: true)
        let first = model.devices[0], second = model.devices[1]
        await model.loadSchedules(for: first); await model.loadSchedules(for: second)
        let other = model.scheduleStates[second.id]
        model.beginScheduleEdit(for: first)
        model.scheduleEdits[first.id]?.draft.minutes = 721
        await model.saveSchedule(for: first)
        await model.loadSchedules(for: first)
        #expect(model.scheduleStates[first.id]?.rules.count == 3)
        #expect(model.scheduleStates[first.id]?.rules.last?.draft.minutes == 721)
        #expect(model.scheduleStates[second.id] == other)
        #expect(model.scheduleEdits[first.id] == nil)
    }

    @Test("Changing an existing weekly rule to once starts with a valid device date")
    func onceDate() async throws {
        let model = KasaModel(demo: true)
        let device = try #require(model.devices.first)
        await model.loadSchedules(for: device)
        var draft = KasaScheduleDraft(); draft.year = 0; draft.month = 0; draft.day = 0
        let rule = KasaScheduleRule(id: "weekly", draft: draft, editable: true, original: Data())
        model.beginScheduleEdit(rule, for: device)
        model.scheduleEdits[device.id]?.draft.repeats = false
        let edit = try #require(model.scheduleEdits[device.id])
        #expect(edit.draft.isValid)
        #expect(edit.draft.year >= 2026)
    }

    @Test("A lost reply retains the draft and blocks duplicate submission until refresh")
    func ambiguousReply() async throws {
        let service = ScheduleFailureService()
        let model = KasaModel(client: service, preferences: nil)
        let device = KasaDevice(id: "fixture", host: "192.0.2.1", name: "Fixture", model: "HS105")
        await model.loadSchedules(for: device)
        model.beginScheduleEdit(for: device)
        await model.saveSchedule(for: device)
        await model.saveSchedule(for: device)
        #expect(await service.writes == 1)
        #expect(model.scheduleEdits[device.id] != nil)
        #expect(model.scheduleErrors[device.id] != nil)
        #expect(model.scheduleNeedsRefresh.contains(device.id))
        await model.loadSchedules(for: device)
        #expect(!model.scheduleNeedsRefresh.contains(device.id))
    }
}
