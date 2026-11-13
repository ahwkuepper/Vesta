// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import KasaKit
import VestaDesign

struct KasaScheduleView: View {
    let device: KasaDevice
    @Bindable var model: KasaModel
    private var busy: Bool { model.scheduleBusy.contains(device.id) }
    private var writable: Bool { !busy && device.canControl && !model.scheduleNeedsRefresh.contains(device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            HStack {
                Text("SCHEDULES").font(.sectionLabel).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.mini).accessibilityLabel("Loading schedules") }
                Button { Task { await model.loadSchedules(for: device) } } label: {
                    Image(systemName: "arrow.clockwise").font(.controlGlyphBold).frame(width: 22, height: 22)
                }.buttonStyle(.plain).disabled(busy)
                    .help("Refresh schedules and device time")
                    .accessibilityLabel("Refresh schedules for \(device.name)")
            }
            if let error = model.scheduleErrors[device.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.messageBody).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let state = model.scheduleStates[device.id] {
                clock(state)
                if let edit = model.scheduleEdits[device.id] {
                    KasaScheduleEditor(device: device, model: model, original: edit.original, writable: writable)
                } else {
                    Toggle("Schedules enabled", isOn: Binding(get: { state.enabled }, set: { value in
                        Task { await model.changeSchedule(.overallEnabled(value), for: device) }
                    }))
                    .font(.messageBody).toggleStyle(.switch).controlSize(.mini).disabled(!writable)
                    if !state.enabled {
                        Text("Schedules are paused on this device.").font(.lightStatus).foregroundStyle(.secondary)
                    }
                    ForEach(state.rules) { rule in schedule(rule) }
                    if state.rules.isEmpty {
                        Text("No schedules yet").font(.messageBody).foregroundStyle(.secondary)
                    }
                    Button { model.beginScheduleEdit(for: device) } label: {
                        Label("Add schedule", systemImage: "plus").chipMetrics().chipStyle()
                    }.buttonStyle(.plain).disabled(!writable)
                        .accessibilityLabel("Add schedule for \(device.name)")
                }
                Text("Runs on the device, even when this Mac is asleep.")
                    .font(.lightStatus).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if busy {
                Text("Reading schedules…").font(.messageBody).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func clock(_ state: KasaScheduleState) -> some View {
        if let clock = state.clock {
            Text("Device time at refresh: \(clock.label)").font(.sectionValue).foregroundStyle(.secondary)
            if clock.differsFromMac() {
                Label("Device time differs from this Mac. Check its location and time zone in the Kasa app.", systemImage: "clock.badge.exclamationmark")
                    .font(.messageBody).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Times use the device’s clock. Its current time couldn’t be read.")
                .font(.lightStatus).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func schedule(_ rule: KasaScheduleRule) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Button { model.beginScheduleEdit(rule, for: device) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: rule.draft.time == .sunrise ? "sunrise" : rule.draft.time == .sunset ? "sunset" : "clock")
                        Text(rule.editable ? "\(rule.draft.timeLabel) · \(rule.draft.power ? "On" : "Off")" : "Custom schedule")
                            .font(.messageTitle)
                    }
                    Text(rule.draft.daysLabel).font(.lightStatus).foregroundStyle(.secondary)
                    if !rule.draft.name.isEmpty { Text(rule.draft.name).font(.lightStatus).foregroundStyle(.secondary).lineLimit(1) }
                    if !rule.editable {
                        Text("Edit advanced settings in Kasa").font(.lightStatus).foregroundStyle(.secondary)
                    } else if rule.draft.power, let brightness = rule.draft.brightness {
                        Text("Brightness \(brightness)%").font(.lightStatus).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!writable || !rule.editable)
                .accessibilityLabel("Edit \(rule.draft.timeLabel) schedule for \(device.name)")
            Toggle("", isOn: Binding(get: { rule.draft.enabled }, set: { value in
                Task { await model.changeSchedule(.enabled(rule, value), for: device) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(!writable)
                .accessibilityLabel("Enable \(rule.draft.timeLabel) schedule for \(device.name)")
        }.padding(.vertical, 4)
    }
}

private struct KasaScheduleEditor: View {
    let device: KasaDevice
    @Bindable var model: KasaModel
    let original: KasaScheduleRule?
    let writable: Bool
    @State private var confirmingDelete = false
    private var draft: KasaScheduleDraft { model.scheduleEdits[device.id]?.draft ?? KasaScheduleDraft() }
    private var busy: Bool { model.scheduleBusy.contains(device.id) }
    private func binding<T>(_ path: WritableKeyPath<KasaScheduleDraft, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: path] }, set: { model.scheduleEdits[device.id]?.draft[keyPath: path] = $0 })
    }
    private var date: Binding<Date> {
        Binding(get: {
            KasaScheduleDraft.calendar.date(from: DateComponents(year: draft.year, month: draft.month, day: draft.day)) ?? Date()
        }, set: { value in
            let parts = KasaScheduleDraft.calendar.dateComponents([.year, .month, .day], from: value)
            model.scheduleEdits[device.id]?.draft.year = parts.year ?? 2026
            model.scheduleEdits[device.id]?.draft.month = parts.month ?? 1
            model.scheduleEdits[device.id]?.draft.day = parts.day ?? 1
        })
    }
    private var time: Binding<Date> {
        Binding(get: {
            KasaScheduleDraft.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: draft.minutes / 60, minute: draft.minutes % 60)) ?? Date()
        }, set: { value in
            let parts = KasaScheduleDraft.calendar.dateComponents([.hour, .minute], from: value)
            model.scheduleEdits[device.id]?.draft.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(original == nil ? "New schedule" : "Edit schedule").font(.messageTitle)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name (optional)", text: binding(\.name)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Schedule name")
                Picker("Action", selection: binding(\.power)) { Text("On").tag(true); Text("Off").tag(false) }
                    .pickerStyle(.segmented)
                Picker("When", selection: binding(\.time)) {
                    ForEach(KasaScheduleTime.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if draft.time == .clock {
                    DatePicker("Device time", selection: time, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, .gmt).environment(\.calendar, KasaScheduleDraft.calendar)
                } else {
                    Stepper(value: binding(\.offset), in: -720...720, step: 1) {
                        Text(draft.offset == 0 ? "At \(draft.time.title.lowercased())" : "\(abs(draft.offset)) min \(draft.offset < 0 ? "before" : "after")")
                            .font(.messageBody)
                    }.accessibilityLabel("Minutes before or after \(draft.time.title.lowercased())")
                    Text("Uses the location saved on this device.").font(.lightStatus).foregroundStyle(.secondary)
                }
                Picker("Repeat", selection: binding(\.repeats)) { Text("Weekly").tag(true); Text("Once").tag(false) }
                    .pickerStyle(.segmented)
                if draft.repeats {
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { day in
                            let selected = draft.weekdays[day]
                            Button { model.scheduleEdits[device.id]?.draft.weekdays[day].toggle() } label: {
                                Text(["S", "M", "T", "W", "T", "F", "S"][day])
                                    .font(.chipLabel).frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .chipStyle(isActive: selected).contentShape(Capsule())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day])
                                .accessibilityValue(selected ? "Selected" : "Not selected")
                                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }.chipGroup(spacing: 4)
                    if !draft.weekdays.contains(true) {
                        Text("Choose at least one day.").font(.lightStatus).foregroundStyle(.orange)
                    }
                } else {
                    DatePicker("Device date", selection: date, displayedComponents: .date)
                        .environment(\.timeZone, .gmt).environment(\.calendar, KasaScheduleDraft.calendar)
                }
                if device.isBulb, device.brightness != nil, draft.power {
                    Toggle("Set brightness", isOn: Binding(get: { draft.brightness != nil }, set: { enabled in
                        model.scheduleEdits[device.id]?.draft.brightness = enabled ? (device.brightness ?? 100) : nil
                    })).font(.messageBody).controlSize(.mini)
                    if let brightness = draft.brightness {
                        HStack {
                            Slider(value: Binding(get: { Double(brightness) }, set: { model.scheduleEdits[device.id]?.draft.brightness = Int($0.rounded()) }), in: 1...100, step: 1)
                                .accessibilityLabel("Scheduled brightness")
                            Text("\(brightness)%").font(.sectionValue).frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                Toggle("Enabled", isOn: binding(\.enabled)).font(.messageBody).controlSize(.mini)
            }.disabled(busy)
            HStack {
                if let original {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash").frame(width: 22, height: 22)
                    }.buttonStyle(.plain).disabled(!writable).accessibilityLabel("Delete schedule")
                        .confirmationDialog("Delete this schedule?", isPresented: $confirmingDelete) {
                            Button("Delete schedule", role: .destructive) {
                                Task {
                                    if await model.changeSchedule(.delete(original), for: device) { model.scheduleEdits[device.id] = nil }
                                }
                            }
                        }
                }
                Spacer()
                Button("Cancel") { model.scheduleEdits[device.id] = nil }.disabled(busy)
                Button("Save") { Task { await model.saveSchedule(for: device) } }
                    .disabled(!writable || !draft.isValid).buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }
    }
}
