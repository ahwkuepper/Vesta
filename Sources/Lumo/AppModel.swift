import Foundation
import Observation
import LumoKit
import LumoBLE
import LumoBridge

/// Owns the active transport.
///
/// The bridge is the real transport and is chosen whenever credentials exist. The
/// simulator is no longer user-selectable — it survives only for tests and offscreen
/// snapshot rendering, where a deterministic set of lights is the point.
@MainActor
@Observable
final class AppModel {

    enum Mode: String, CaseIterable, Identifiable {
        case bridge
        case bluetooth

        var id: String { rawValue }
        var title: String { self == .bridge ? "Bridge" : "Bluetooth" }
    }

    /// Whether bridge credentials exist. Read once, then cached.
    ///
    /// This was a computed property that called `BridgeStore.load()`, and the
    /// settings menu reads it — so every SwiftUI layout pass performed a
    /// synchronous Keychain decrypt, an IPC round-trip to securityd, on the main
    /// thread inside a view body. In any process holding no ACL for the item —
    /// which includes every unsigned build, and so the offscreen snapshot
    /// renderer — securityd instead waits on a user prompt that a headless run can
    /// never present, and layout blocks forever. Pairing changes roughly once in
    /// the app's lifetime; asking the Keychain per frame was never the right shape.
    private(set) var isBridgePaired = false

    /// Bridge is only offered once we hold credentials for one.
    var availableModes: [Mode] {
        isBridgePaired ? Mode.allCases : [.bluetooth]
    }

    private(set) var mode: Mode = .bluetooth
    private(set) var store: LightStore
    private(set) var isStarting = false

    init() {
        if let credentials = BridgeStore.load() {
            isBridgePaired = true
            mode = .bridge
            store = LightStore(transport: BridgeTransport(credentials: credentials))
        } else {
            store = LightStore(transport: BLETransport())
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
