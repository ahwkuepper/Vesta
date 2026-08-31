// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import VestaKit
import VestaBLE
import VestaBridge

/// Owns the active transport.
///
/// The bridge is the real transport and is chosen whenever credentials exist. The
/// simulator is no longer user-selectable — it survives only for tests and offscreen
/// snapshot rendering, where a deterministic set of lights is the point.
@MainActor
@Observable
final class AppModel {

    /// The transport in use. Defined in VestaKit so the diagnostics report and the
    /// CLI can name it without depending on the interface.
    typealias Mode = TransportMode

    /// Whether bridge credentials exist. Cached, and re-checked when the popover
    /// opens.
    ///
    /// Not a computed property: the settings menu reads it, so a Keychain call here
    /// meant a synchronous decrypt — an IPC round-trip to securityd — on the main
    /// thread inside a view body, every layout pass. In a process without an ACL for
    /// the item, securityd waits on a prompt that a headless run can never present,
    /// and layout blocks forever.
    ///
    /// But caching it at launch alone was a trap: a Keychain read that failed once,
    /// for any reason, left the app in Bluetooth mode for the whole session with the
    /// mode picker hidden — no lights, and no way back short of quitting. It is
    /// re-read whenever the popover opens.
    private(set) var isBridgePaired = false

    /// Set when the Keychain refused to answer, as opposed to there being nothing
    /// paired. Shown to the user rather than silently degrading.
    private(set) var credentialFailure: OSStatus?

    /// Bridge is offered once we hold credentials, and also whenever we know we are
    /// paired but could not read the item — otherwise the one control that recovers
    /// the situation is hidden exactly when it is needed.
    var availableModes: [Mode] {
        isBridgePaired ? Mode.allCases : [.bluetooth]
    }

    private(set) var mode: Mode = .bluetooth
    private(set) var store: LightStore
    private(set) var isStarting = false

    init() {
        switch BridgeStore.read() {
        case .paired(let credentials):
            isBridgePaired = true
            mode = .bridge
            store = LightStore(transport: BridgeTransport(credentials: credentials))
        case .notPaired:
            store = LightStore(transport: BLETransport())
        case .unreadable(let status):
            credentialFailure = status
            Log.setup.error("could not read bridge credentials: \(status, privacy: .public)")
            store = LightStore(transport: BLETransport())
        }
    }

    /// Adopts credentials that pairing has just written.
    ///
    /// Same path as recovery — the Keychain is the single source of truth for
    /// whether a bridge is paired, so nothing is passed in by hand.
    func adoptNewPairing() async {
        await recoverBridgeIfPossible()
    }

    /// Re-reads pairing state and adopts the bridge if it has become readable.
    ///
    /// Called on every popover open, so a Keychain read that failed at launch — a
    /// rebuild that changed the ACL, an item being rewritten by a CLI run, a locked
    /// keychain — recovers by itself instead of stranding the session.
    private func recoverBridgeIfPossible() async {
        guard mode != .bridge else { return }
        switch BridgeStore.read() {
        case .paired(let credentials):
            credentialFailure = nil
            isBridgePaired = true
            mode = .bridge
            store = LightStore(transport: BridgeTransport(credentials: credentials))
            hasStarted = true
            await store.start()
            Log.setup.info("bridge credentials became readable; switched to Bridge")
        case .notPaired:
            credentialFailure = nil
        case .unreadable(let status):
            credentialFailure = status
        }
    }

    /// Used by offscreen snapshot rendering, which needs a fully-populated store
    /// without waiting on discovery.
    init(previewStore: LightStore) {
        store = previewStore
        isPreview = true
    }

    private(set) var isPreview = false

    private var hasStarted = false

    func start() async {
        guard !isPreview else { return }
        await recoverBridgeIfPossible()
        if hasStarted {
            // Reopening the popover: the lights may have been changed from the Hue
            // app, a switch or a routine since it was last shown.
            await store.resync()
            await store.refreshRoomsAndScenes()
            return
        }
        hasStarted = true
        await store.start()
    }

    func switchTo(_ newMode: Mode) async {
        guard newMode != mode else { return }
        isStarting = true
        defer { isStarting = false }

        mode = newMode
        let transport: LightTransport
        switch newMode {
        case .bridge:
            guard let credentials = BridgeStore.load() else {
                // Credentials vanished — cleared, or the ACL was lost. Stop
                // offering a mode that cannot work.
                isBridgePaired = false
                mode = .bluetooth
                transport = BLETransport()
                break
            }
            isBridgePaired = true
            transport = BridgeTransport(credentials: credentials)
        case .bluetooth:
            transport = BLETransport()
        }
        store = LightStore(transport: transport)
        await store.start()
    }

    /// The menu bar icon reflects the room at a glance — filled when anything is
    /// lit, outline when everything is off.
    var menuBarSymbol: String {
        store.anyLightOn ? "lightbulb.fill" : "lightbulb"
    }
}
