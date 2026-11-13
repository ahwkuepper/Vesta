// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OSLog
import KasaKit
import KasaTransport

@MainActor
@Observable
final class KasaModel {
    var devices: [KasaDevice] = []
    var isRefreshing = false
    var isSigningIn = false
    var signedIn = false
    var error: String?
    var busy: Set<String> = []
    var brightnessDraft: [String: Int] = [:]
    var controlDraft: [String: KasaCommand] = [:]
    var scheduleStates: [String: KasaScheduleState] = [:]
    var scheduleBusy: Set<String> = []
    var scheduleErrors: [String: String] = [:]
    var scheduleNeedsRefresh: Set<String> = []
    var scheduleEdits: [String: KasaScheduleEdit] = [:]
    var lastUpdated: Date?
    var search = ""
    let demo: Bool

    @ObservationIgnored private let client: any KasaServing
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private var credentials: KasaCredentials?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var lastDiscovery = Date.distantPast
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.ahwkuepper.VestaKasa", category: "devices")
    private static let cacheKey = "kasa.devices.v1"

    init(demo: Bool = false, client: any KasaServing = KasaClient(), preferences: UserDefaults? = .standard) {
        self.demo = demo
        self.client = client
        self.preferences = preferences
        if demo { devices = Self.examples; signedIn = true; lastUpdated = Date() }
    }

    var lights: [KasaDevice] { filtered.filter(\.isBulb) }
    var plugs: [KasaDevice] { filtered.filter { !$0.isBulb } }
    var filtered: [KasaDevice] {
        devices.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.model.localizedStandardContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var requiresSignIn: Bool { devices.contains { $0.connection == .signInRequired } }
    func reloadCredentials() async {
        guard !isSigningIn, !isRefreshing else { return }
        do { credentials = try await Task.detached { try KasaKeychain.load() }.value; signedIn = credentials != nil; error = nil }
        catch { report(error) }
    }
    var anyOn: Bool { devices.contains { $0.canControl && $0.isOn } }
    var summary: String {
        if devices.isEmpty { return isRefreshing ? "Looking for devices…" : "Your home, together" }
        let available = devices.filter(\.canControl)
        let on = available.filter(\.isOn).count
        if available.isEmpty { return "\(devices.count) found · reconnecting" }
        return on == 0 ? "All off" : "\(on) of \(devices.count) on"
    }

    func start() async {
        guard !started, !demo else { return }
        started = true
        do { credentials = try await Task.detached { try KasaKeychain.load() }.value; signedIn = credentials != nil }
        catch { report(error) }
        if let data = preferences?.data(forKey: Self.cacheKey), data.count < 262_144,
           let cached = try? JSONDecoder().decode([KasaDevice].self, from: data) {
            devices = cached.prefix(256).map { var copy = $0; copy.connection = .offline; return copy }
        }
        await refresh(discover: true)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                await self.refresh(discover: Date().timeIntervalSince(self.lastDiscovery) > 60)
            }
        }
    }

    func refresh(discover: Bool = false) async {
        guard !isRefreshing, !isSigningIn, !demo else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let versions = revisions
        if discover || devices.isEmpty {
            do {
                let found = try await client.discover()
                lastDiscovery = Date()
                for var device in found {
                    // Keep names and capability information while reconnecting to locked devices.
                    if let previous = devices.first(where: { $0.id == device.id || ($0.host == device.host && $0.childID == nil) }) {
                        if device.connection == .signInRequired {
                            let host = device.host, transport = device.transport
                            device = previous; device.host = host; device.transport = transport
                            device.connection = .signInRequired
                        }
                    }
                    if !devices.contains(where: { $0.parentID == device.id }) { merge([device], versions: versions) }
                }
            } catch { report(error) }
        }
        let credentials = credentials
        // Strip outlets share a host. Read their parent only once.
        var hosts = Set<String>()
        let targets = devices.filter { device in
            guard device.transport != .unsupported, !busy.contains(device.id), controlDraft[device.id] == nil else { return false }
            return hosts.insert(device.host).inserted
        }
        await withTaskGroup(of: (KasaDevice, Result<[KasaDevice], KasaError>).self) { group in
            // Batches keep a large LAN from opening unbounded concurrent connections.
            for batchStart in stride(from: 0, to: targets.count, by: 8) {
                for device in targets[batchStart..<min(batchStart + 8, targets.count)] {
                    group.addTask { [client] in
                        do { return (device, .success(try await client.read(device, credentials: credentials))) }
                        catch { return (device, .failure(error as? KasaError ?? .unavailable)) }
                    }
                }
                for await (device, result) in group {
                    switch result {
                    case .success(let updated): merge(updated, versions: versions)
                    case .failure(let problem):
                        for index in devices.indices where devices[index].host == device.host {
                            let id = devices[index].id
                            guard !busy.contains(id), controlDraft[id] == nil,
                                  revisions[id, default: 0] == versions[id, default: 0] else { continue }
                            devices[index].connection = problem == .authentication ? .signInRequired : .offline
                        }
                    }
                }
            }
        }
        lastUpdated = Date()
        persistDevices()
    }

    private func merge(_ updated: [KasaDevice], versions: [String: Int]? = nil) {
        for device in updated {
            if let versions, (busy.contains(device.id) || controlDraft[device.id] != nil || revisions[device.id, default: 0] != versions[device.id, default: 0]) { continue }
            if let parent = device.parentID { devices.removeAll { $0.id == parent } }
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
            else if devices.count < 256 { devices.append(device) }
        }
    }

    func signIn(email: String, password: String) async -> Bool {
        guard !isRefreshing, !isSigningIn else { return false }
        guard let target = devices.first(where: { $0.transport == .klap }) else {
            error = "No devices needing sign-in were found. Refresh while connected to your home Wi-Fi."
            return false
        }
        isSigningIn = true
        let candidate = KasaCredentials(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        do {
            let updated = try await client.read(target, credentials: candidate)
            try KasaKeychain.save(candidate)
            credentials = candidate; signedIn = true; error = nil
            merge(updated)
            isSigningIn = false
            await refresh()
            return true
        } catch {
            report(error)
            isSigningIn = false
            return false
        }
    }

    func signOut() {
        guard busy.isEmpty, !isRefreshing, !isSigningIn else { return }
        do {
            try KasaKeychain.delete()
            credentials = nil; signedIn = false
            for index in devices.indices where devices[index].transport == .klap {
                devices[index].connection = .signInRequired
            }
        } catch { report(error) }
    }

    func setBrightness(_ value: Int, for device: KasaDevice) {
        setControl(.brightness(min(100, max(1, value))), for: device)
    }

    func setControl(_ command: KasaCommand, for device: KasaDevice) {
        guard device.canControl, !busy.contains(device.id) else { return }
        if case .brightness(let value) = command { brightnessDraft[device.id] = value }
        else { brightnessDraft[device.id] = nil }
        controlDraft[device.id] = command
        pending[device.id]?.cancel()
        pending[device.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            self.pending[device.id] = nil
            await self.perform(command, device: device)
            self.brightnessDraft[device.id] = nil
            self.controlDraft[device.id] = nil
        }
    }

    @discardableResult
    func command(_ command: KasaCommand, device: KasaDevice) -> Task<Void, Never>? {
        guard !busy.contains(device.id) else { return nil }
        pending.removeValue(forKey: device.id)?.cancel()
        brightnessDraft[device.id] = nil
        controlDraft[device.id] = nil
        return Task { await perform(command, device: device) }
    }

    private func perform(_ command: KasaCommand, device: KasaDevice) async {
        guard device.canControl, !busy.contains(device.id) else { return }
        busy.insert(device.id)
        revisions[device.id, default: 0] += 1
        defer { busy.remove(device.id) }
        if demo {
            guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
            switch command {
            case .power(let on): devices[index].isOn = on
            case .brightness(let brightness): devices[index].brightness = brightness
            case .temperature(let temperature): devices[index].colorTemperature = temperature
            case .color(let hue, let saturation): devices[index].hue = hue; devices[index].saturation = saturation; devices[index].colorTemperature = 0
            }
            return
        }
        do {
            try await client.apply(command, to: device, credentials: credentials)
            merge(try await client.read(device, credentials: credentials))
            persistDevices()
        } catch {
            report(error)
            // A lost reply is ambiguous: read back instead of replaying the mutation.
            do { merge(try await client.read(device, credentials: credentials)) }
            catch {
                if let index = devices.firstIndex(where: { $0.id == device.id }) {
                    devices[index].connection = (error as? KasaError) == .authentication ? .signInRequired : .offline
                }
            }
        }
    }

    func loadSchedules(for device: KasaDevice) async {
        guard !scheduleBusy.contains(device.id) else { return }
        scheduleBusy.insert(device.id)
        defer { scheduleBusy.remove(device.id) }
        do {
            if demo {
                if scheduleStates[device.id] == nil {
                    var evening = KasaScheduleDraft()
                    evening.time = .sunset; evening.brightness = device.isBulb ? 70 : nil
                    var night = KasaScheduleDraft(); night.minutes = 23 * 60; night.power = false
                    let wall = Date().addingTimeInterval(Double(TimeZone.current.secondsFromGMT()))
                    scheduleStates[device.id] = KasaScheduleState(rules: [
                        KasaScheduleRule(id: "evening", draft: evening, editable: true, original: Data()),
                        KasaScheduleRule(id: "night", draft: night, editable: true, original: Data())
                    ], enabled: true, clock: KasaDeviceClock(wallTime: wall))
                }
            } else { scheduleStates[device.id] = try await client.schedules(device, credentials: credentials) }
            scheduleErrors[device.id] = nil
            scheduleNeedsRefresh.remove(device.id)
        } catch {
            logger.error("Schedule operation failed; the device panel shows the recovery action.")
            scheduleErrors[device.id] = error.localizedDescription
            scheduleNeedsRefresh.insert(device.id)
        }
    }

    func beginScheduleEdit(_ rule: KasaScheduleRule? = nil, for device: KasaDevice) {
        var draft = rule?.draft ?? KasaScheduleDraft()
        if rule == nil || draft.repeats {
            let wall = scheduleStates[device.id]?.clock?.wallTime
                ?? Date().addingTimeInterval(Double(TimeZone.current.secondsFromGMT()))
            let parts = KasaScheduleDraft.calendar.dateComponents([.year, .month, .day], from: wall)
            draft.year = parts.year ?? 2026; draft.month = parts.month ?? 1; draft.day = parts.day ?? 1
        }
        scheduleEdits[device.id] = KasaScheduleEdit(draft: draft, original: rule)
    }

    func saveSchedule(for device: KasaDevice) async {
        guard let edit = scheduleEdits[device.id] else { return }
        if await changeSchedule(.save(edit.draft, replacing: edit.original), for: device) {
            scheduleEdits[device.id] = nil
        }
    }

    @discardableResult
    func changeSchedule(_ change: KasaScheduleChange, for device: KasaDevice) async -> Bool {
        guard device.canControl, !scheduleBusy.contains(device.id),
              !scheduleNeedsRefresh.contains(device.id), var state = scheduleStates[device.id] else { return false }
        scheduleBusy.insert(device.id)
        defer { scheduleBusy.remove(device.id) }
        do {
            if demo {
                switch change {
                case .overallEnabled(let enabled): state.enabled = enabled
                case .delete(let rule): state.rules.removeAll { $0.id == rule.id }
                case .enabled(let rule, let enabled):
                    if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
                        var draft = rule.draft; draft.enabled = enabled
                        state.rules[index] = KasaScheduleRule(id: rule.id, draft: draft, editable: rule.editable, original: rule.original)
                    }
                case .save(let draft, let previous):
                    guard draft.isValid else { throw KasaScheduleError.invalid }
                    let rule = KasaScheduleRule(id: previous?.id ?? UUID().uuidString, draft: draft, editable: true, original: Data())
                    if let index = state.rules.firstIndex(where: { $0.id == rule.id }) { state.rules[index] = rule }
                    else { state.rules.append(rule) }
                }
                scheduleStates[device.id] = state
            } else {
                scheduleStates[device.id] = try await client.changeSchedule(change, device: device, credentials: credentials)
            }
            scheduleErrors[device.id] = nil
            return true
        } catch {
            logger.error("Schedule operation failed; the device panel shows the recovery action.")
            scheduleErrors[device.id] = error.localizedDescription
            // Require a fresh read before another attempt. This prevents accidental
            // duplicate adds after ambiguous replies and stale edits from another app.
            scheduleNeedsRefresh.insert(device.id)
            return false
        }
    }

    private func persistDevices() {
        guard let encoded = try? JSONEncoder().encode(devices) else { return }
        preferences?.set(encoded, forKey: Self.cacheKey)
    }

    private func report(_ problem: Error) {
        let message = (problem as? KasaError)?.localizedDescription ?? "The device couldn’t be reached. Try refreshing."
        error = message
        logger.error("\(message, privacy: .public)")
    }

    static var examples: [KasaDevice] { [
        KasaDevice(id: "demo-bulb-1", host: "192.0.2.1", name: "Porch · Left", model: "KL110", isBulb: true, isOn: true, brightness: 68),
        KasaDevice(id: "demo-bulb-2", host: "192.0.2.2", name: "Porch · Right", model: "KL110", isBulb: true, isOn: true, brightness: 68),
        KasaDevice(id: "demo-bulb-3", host: "192.0.2.3", name: "Reading lamp", model: "KL130", isBulb: true, isOn: false, brightness: 45, colorTemperature: 2700, supportsColor: true, supportsTemperature: true),
        KasaDevice(id: "demo-plug-1", host: "192.0.2.4", name: "Bedroom lamp", model: "HS105", isOn: true),
        KasaDevice(id: "demo-plug-2", host: "192.0.2.5", name: "Desk lamp", model: "EP10", isOn: false),
        KasaDevice(id: "demo-plug-3", host: "192.0.2.6", name: "String lights", model: "HS105", isOn: true),
        KasaDevice(id: "demo-plug-4", host: "192.0.2.7", name: "Charger", model: "EP10", isOn: true)
    ] }
}

struct KasaScheduleEdit {
    var draft: KasaScheduleDraft
    let original: KasaScheduleRule?
}
