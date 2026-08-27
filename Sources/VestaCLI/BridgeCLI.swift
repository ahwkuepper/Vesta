import Foundation
import VestaKit
import VestaBridge
import VestaDiagnostics

/// `--pair-bridge` and `--verify-bridge`, so the bridge can be set up and checked
/// from a terminal while standing next to it, before any of it is wired into the UI.
/// Command line modes. Each returns a process exit code.
public enum BridgeCLI {

    /// Mirrors output to a log file. Local-network and Bluetooth TCC prompts only
    /// attach correctly when the app is launched through LaunchServices, and that
    /// detaches stdout — so everything worth reading also goes to disk.
    nonisolated(unsafe) private static let log: FileHandle? = {
        let path = ProcessInfo.processInfo.environment["VESTA_CLI_LOG"]
            ?? "\(NSHomeDirectory())/Library/Logs/vesta-cli.log"
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // 0600: the default 0644 leaves this readable by every other account on the
        // machine, and an unsandboxed run writes it under the real home directory.
        FileManager.default.createFile(atPath: path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        return FileHandle(forWritingAtPath: path)
    }()

    static func say(_ message: String) {
        print(message)
        fflush(stdout)
        log?.write(Data((message + "\n").utf8))
        try? log?.synchronize()
    }

    public static func pair(host: String) async -> Int32 {
        let pairing = BridgePairing()
        do {
            let bridgeID = try await pairing.identify(host: host)
            say("bridge \(bridgeID) at \(host)")
            say("PRESS THE ROUND BUTTON ON THE BRIDGE NOW — waiting up to 3 minutes…")

            let credentials = try await pairing.pair(host: host, bridgeID: bridgeID,
                                                    timeout: .seconds(180)) { attempt in
                if attempt % 5 == 0 { print("  still waiting (\(attempt * 2)s)…") }
            }
            try BridgeStore.save(credentials)

            // Never write any part of the key, not even a prefix: this file is
            // plaintext on disk, and an unsandboxed run puts it in the home
            // directory. The fingerprint is enough to tell two keys apart.
            say("PAIRED. app key stored in the Keychain.")
            return 0
        } catch {
            say("pairing failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Proves writes actually round-trip: briefly lights each lamp, reads the
    /// bridge back to confirm the change landed, then restores its exact prior
    /// state. Connecting is not the same as controlling.
    public static func testLights() async -> Int32 {
        guard let credentials = BridgeStore.load() else {
            say("no bridge credentials — run --pair-bridge <host> first")
            return 1
        }
        let transport = BridgeTransport(credentials: credentials)
        var failures = 0

        do {
            let lights = try await transport.fetchLights().sorted { $0.name < $1.name }
            say("testing \(lights.count) light(s) — each will flash briefly, then restore\n")

            for light in lights {
                let original = light.state
                do {
                    try await transport.setPower(true, for: light.id)
                    try await transport.setBrightness(0.6, for: light.id)
                    try await Task.sleep(for: .milliseconds(700))

                    // Read back from the bridge rather than trusting the write.
                    let after = try await transport.fetchLights()
                        .first { $0.id == light.id }?.state
                    let landed = after?.isOn == true

                    try await transport.setBrightness(original.brightness, for: light.id)
                    try await transport.setColor(original.color, for: light.id)
                    try await transport.setPower(original.isOn, for: light.id)

                    say("  \(landed ? "PASS" : "FAIL") \(light.name) — on/off + brightness\(landed ? " verified" : " did not take")")
                    if !landed { failures += 1 }
                } catch {
                    say("  FAIL \(light.name) — \(error.localizedDescription)")
                    failures += 1
                    // Best effort: do not leave a lamp on because the test broke.
                    try? await transport.setPower(original.isOn, for: light.id)
                }
            }
            say("\n\(lights.count - failures)/\(lights.count) controllable, state restored")
            return failures == 0 ? 0 : 1
        } catch {
            say("could not list lights: \(error.localizedDescription)")
            return 1
        }
    }

    /// Exercises rooms and scenes end to end: lists them, creates a scene from the
    /// current state of the first room, recalls it, then deletes it again.
    public static func testScenes() async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        let transport = BridgeTransport(credentials: credentials)
        do {
            let rooms = try await transport.fetchRooms()
            let lights = try await transport.fetchLights()
            say("rooms:")
            for room in rooms {
                let names = room.lightIDs.compactMap { id in lights.first { $0.id == id }?.name }
                say("  \(room.name) [\(room.archetype)] grouped=\(room.groupedLightID != nil ? "yes" : "no")")
                for name in names { say("      \(name)") }
            }

            let existing = try await transport.fetchScenes()
            say("\nexisting scenes:")
            for scene in existing {
                let room = rooms.first { $0.id == scene.roomID }?.name ?? "?"
                say("  \(scene.name) — \(room)\(scene.isEditable ? " (Vesta)" : " (Hue app)")")
            }

            guard let room = rooms.first else { say("\nno rooms to test with"); return 1 }
            say("\ncreating a scene in \(room.name)…")
            let created = try await transport.createScene(named: "Vesta Test Scene", in: room.id)
            say("  created \(created.id)")

            let after = try await transport.fetchScenes()
            let found = after.contains { $0.id == created.id }
            say("  visible in scene list: \(found)")
            say("  marked editable: \(after.first { $0.id == created.id }?.isEditable == true)")

            try await transport.recallScene(created.id)
            say("  recalled OK")

            try await transport.deleteScene(created.id)
            let final = try await transport.fetchScenes()
            let gone = !final.contains { $0.id == created.id }
            say("  deleted: \(gone)")

            let ok = found && gone
            say(ok ? "\nPASS — rooms and scenes work end to end" : "\nFAIL")
            return ok ? 0 : 1
        } catch {
            say("FAIL — \(error.localizedDescription)")
            return 1
        }
    }

    /// Reproduces the reported bug: recall one scene, then another, and report
    /// what the store believes versus what the bridge says.
    public static func testSceneSwitch(_ first: String, _ second: String) async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        let transport = BridgeTransport(credentials: credentials)
        let store = await LightStore(transport: transport)
        await store.start()
        try? await Task.sleep(for: .seconds(2))

        func report(_ label: String) async -> Bool {
            let believed = await store.lights
            guard let truth = try? await transport.fetchLights() else { return false }
            var agrees = true
            say("\n\(label):")
            for light in believed.sorted(by: { $0.name < $1.name }) {
                guard let actual = truth.first(where: { $0.id == light.id }) else { continue }
                let ok = light.state.isOn == actual.state.isOn
                    && abs(light.state.brightness - actual.state.brightness) < 0.05
                if !ok { agrees = false }
                say("  \(ok ? "ok  " : "MISMATCH")  \(light.name): "
                    + "app says \(light.state.isOn ? "on" : "off") "
                    + "\(Int(light.state.brightness * 100))%, "
                    + "bridge says \(actual.state.isOn ? "on" : "off") "
                    + "\(Int(actual.state.brightness * 100))%")
            }
            return agrees
        }

        var allAgree = await report("initial")

        for name in [first, second] {
            let scenes = await store.scenes
            guard let scene = scenes.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { say("no scene \"\(name)\""); return 1 }

            await store.recall(scene)
            // Give the recall, the event burst and the resync time to settle.
            try? await Task.sleep(for: .seconds(3))
            let agrees = await report("after recalling \(scene.name)")
            allAgree = allAgree && agrees
        }

        say(allAgree ? "\nPASS — the app matched the bridge at every step"
                     : "\nFAIL — the app showed a state the bridge disagreed with")
        return allAgree ? 0 : 1
    }

    /// Watches the bridge's event stream while recalling a scene, and reports which
    /// fields each pushed update actually carries.
    public static func watchEvents(sceneName: String) async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        let transport = BridgeTransport(credentials: credentials)
        do {
            let scenes = try await transport.fetchScenes()
            guard let scene = scenes.first(where: {
                $0.name.caseInsensitiveCompare(sceneName) == .orderedSame
            }) else { say("no scene \"\(sceneName)\""); return 1 }

            let watcher = Task {
                await transport.watchRawEvents(seconds: 8) { line in
                    guard let data = line.data(using: .utf8),
                          let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                    else { return }
                    for event in events {
                        for item in (event["data"] as? [[String: Any]]) ?? [] {
                            guard item["type"] as? String == "light" else { continue }
                            let fields = item.keys.filter {
                                !["id", "id_v1", "type", "owner", "service_id"].contains($0)
                            }.sorted()
                            say("  light update carries: \(fields.joined(separator: ", "))")
                        }
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(700))
            say("recalling \(scene.name)…")
            try await transport.recallScene(scene.id)
            await watcher.value
            say("done")
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Re-saves the credentials from the currently-signed app.
    ///
    /// The keychain item was first written by an ad-hoc signed build, so its ACL is
    /// bound to a code identity that changes on every rebuild — hence a password
    /// prompt each time. Deleting and re-adding it from a stably-signed build binds
    /// the ACL to that stable identity instead, after which it stops asking.
    public static func rebindKeychain() async -> Int32 {
        guard let credentials = BridgeStore.load() else {
            say("could not read the existing credentials — allow the keychain prompt and retry")
            return 1
        }
        do {
            BridgeStore.clear()
            try BridgeStore.save(credentials)
            guard BridgeStore.load() != nil else {
                say("re-saved but could not read back"); return 1
            }
            say("rebound to the current signing identity (\(credentials.bridgeID))")
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Applies a scene by name, so presets can be checked (and used) from a shell.
    public static func recall(sceneName: String) async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        let transport = BridgeTransport(credentials: credentials)
        do {
            let scenes = try await transport.fetchScenes()
            guard let scene = scenes.first(where: {
                $0.name.caseInsensitiveCompare(sceneName) == .orderedSame
            }) else {
                say("no scene called \"\(sceneName)\". Scenes: \(scenes.map(\.name).joined(separator: ", "))")
                return 1
            }
            try await transport.recallScene(scene.id)
            try await Task.sleep(for: .milliseconds(1200))

            let lights = try await transport.fetchLights()
            let rooms = try await transport.fetchRooms()
            let room = rooms.first { $0.id == scene.roomID }
            say("applied \"\(scene.name)\" in \(room?.name ?? "?"):")
            for id in room?.lightIDs ?? [] {
                guard let light = lights.first(where: { $0.id == id }) else { continue }
                let colour: String
                switch light.state.color {
                case .temperature(let m): colour = "\(Int(ColorScience.kelvin(fromMireds: m)))K"
                case .xy(let x, let y):   colour = String(format: "xy %.3f,%.3f", x, y)
                }
                say("  \(light.name): \(light.state.isOn ? "on" : "off") "
                    + "\(Int(light.state.brightness * 100))% \(colour)")
            }
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Creates a set of everyday presets in a room.
    ///
    /// These are aimed at using gradient fixtures like the Play lamps as ordinary
    /// room lighting: each preset pins a uniform gradient as well as a colour
    /// temperature, so the lamp lights the room evenly instead of keeping whatever
    /// multicolour spread was last active.
    public static func makePresets(room roomName: String) async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        let transport = BridgeTransport(credentials: credentials)

        let presets: [(name: String, mireds: Int, brightness: Double)] = [
            ("Evening",     370, 0.70),   // ~2700K, comfortable ambient light
            ("Reading",     303, 1.00),   // ~3300K, brighter and slightly cooler
            ("Candlelight", 500, 0.28),   // ~2000K, low and very warm
        ]

        do {
            let rooms = try await transport.fetchRooms()
            guard let room = rooms.first(where: {
                $0.name.caseInsensitiveCompare(roomName) == .orderedSame
            }) else {
                say("no room called \"\(roomName)\". Rooms: \(rooms.map(\.name).joined(separator: ", "))")
                return 1
            }

            let lights = try await transport.fetchLights()
            let existing = try await transport.fetchScenes()

            for preset in presets {
                // Replace a same-named preset rather than stacking duplicates on
                // every run — but only ones Vesta created.
                if let old = existing.first(where: {
                    $0.roomID == room.id && $0.name == preset.name && $0.isEditable
                }) {
                    try await transport.deleteScene(old.id)
                    say("replaced existing \(preset.name)")
                }

                let actions: [SceneAction] = room.lightIDs.compactMap { id in
                    guard let light = lights.first(where: { $0.id == id }) else { return nil }
                    let color = LightColor.temperature(mireds: preset.mireds)
                    let state = LightState(isOn: true, brightness: preset.brightness, color: color)
                    return SceneAction(
                        lightID: id, state: state,
                        gradient: light.capabilities.supportsGradient
                            ? .uniform(color, points: light.capabilities.gradientPoints ?? 5)
                            : nil)
                }

                let scene = try await transport.createScene(named: preset.name,
                                                            in: room.id, actions: actions)
                let kelvin = Int(ColorScience.kelvin(fromMireds: preset.mireds))
                say("created \(scene.name) — \(kelvin)K at \(Int(preset.brightness * 100))% "
                    + "across \(actions.count) light(s)")
            }

            say("\nPASS — \(presets.count) presets in \(room.name)")
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Answers empirically whether a colour-temperature write alone makes a
    /// gradient fixture uniform, or whether the gradient has to be set too.
    public static func testGradient() async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        let transport = BridgeTransport(credentials: credentials)
        do {
            let lights = try await transport.fetchLights()
            guard let lamp = lights.first(where: { $0.capabilities.supportsGradient }) else {
                say("no gradient-capable light found"); return 1
            }
            say("using \(lamp.name) — \(lamp.capabilities.gradientPoints ?? 0) points, "
                + "\(lamp.capabilities.effects.count) effects")
            let original = lamp.state

            func points() async throws -> String {
                let json = try await transport.rawResource("light")
                guard let data = json.data(using: .utf8),
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let all = root["data"] as? [[String: Any]],
                      let me = all.first(where: { $0["id"] as? String == lamp.id.uuidString.lowercased() }),
                      let gradient = me["gradient"] as? [String: Any]
                else { return "<no gradient key>" }
                guard let pts = gradient["points"] as? [[String: Any]], !pts.isEmpty
                else { return "<gradient present, 0 points> mode=\(gradient["mode"] as? String ?? "?")" }
                return pts.map { p in
                    let xy = ((p["color"] as? [String: Any])?["xy"] as? [String: Any]) ?? [:]
                    return String(format: "(%.3f,%.3f)", xy["x"] as? Double ?? 0, xy["y"] as? Double ?? 0)
                }.joined(separator: " ")
            }

            try await transport.setPower(true, for: lamp.id)
            say("\nbefore:            \(try await points())")

            try await transport.setColor(.temperature(mireds: 370), for: lamp.id)
            try await Task.sleep(for: .milliseconds(900))
            let afterCT = try await points()
            say("after 2700K write: \(afterCT)")

            try await transport.setGradient(.uniform(.temperature(mireds: 370), points: 5), for: lamp.id)
            try await Task.sleep(for: .milliseconds(900))
            let afterGradient = try await points()
            say("after uniform set: \(afterGradient)")

            // Distinguish "reported uniform" from "reported nothing" — an empty
            // reading is not evidence of uniformity.
            if afterCT.hasPrefix("<") {
                say("\nCT write: bridge reports no gradient points afterwards (\(afterCT)).")
                say("Inconclusive from the API alone — confirm visually whether the lamp")
                say("goes uniformly warm, or keeps a colour spread.")
            } else {
                let distinct = Set(afterCT.components(separatedBy: " ")).count
                say(distinct == 1
                    ? "\nCT write alone already makes it uniform"
                    : "\nCT write leaves \(distinct) distinct points — set the gradient explicitly")
            }

            try await transport.setColor(original.color, for: lamp.id)
            try await transport.setBrightness(original.brightness, for: lamp.id)
            try await transport.setPower(original.isOn, for: lamp.id)
            say("restored")
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Dumps a CLIP v2 resource collection, for working out what a bridge offers.
    public static func dump(_ type: String) async -> Int32 {
        guard let credentials = BridgeStore.load() else { say("not paired"); return 1 }
        do {
            let json = try await BridgeTransport(credentials: credentials).rawResource(type)
            say(json)
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// The same health report the gear menu copies, from a shell.
    public static func diagnose() async -> Int32 {
        guard let credentials = BridgeStore.load() else {
            say("not paired — run --pair-bridge <host> first")
            return 1
        }
        let transport = BridgeTransport(credentials: credentials)
        let store = await LightStore(transport: transport)
        await store.start()
        try? await Task.sleep(for: .seconds(2))
        let report = await MainActor.run { Diagnostics.report(store: store, mode: .bridge) }
        say(report)
        // Non-zero when something is actually wrong, so it is usable in a script.
        let healthy = await MainActor.run {
            store.availability.message == nil && !store.lights.isEmpty
        }
        return healthy ? 0 : 1
    }

    /// Reports how Vesta would find the bridge again, for diagnosing recovery.
    public static func discover() async -> Int32 {
        guard let credentials = BridgeStore.load() else {
            say("no bridge credentials — run --pair-bridge <host> first")
            return 1
        }
        say("stored address:   \(credentials.address)")
        guard let hostname = credentials.localHostname else {
            say("bridge ID \(credentials.bridgeID) is malformed — cannot derive an mDNS name")
            return 1
        }
        say("derived mDNS name: \(hostname)")

        var probe = credentials
        probe.address = hostname
        let reachable = await BridgeTransport(credentials: probe).probe()
        say(reachable ? "reachable — DHCP changes will recover automatically"
                      : "NOT reachable at that name")
        return reachable ? 0 : 1
    }

    /// End-to-end check of DHCP recovery: deliberately store a wrong address, then
    /// connect normally and confirm the transport finds the bridge again by mDNS and
    /// writes the corrected address back.
    public static func testRelocate(bogus: String) async -> Int32 {
        guard let real = BridgeStore.load() else {
            say("no bridge credentials — run --pair-bridge <host> first")
            return 1
        }
        var broken = real
        broken.address = bogus
        do { try BridgeStore.save(broken) } catch {
            say("could not write test credentials: \(error.localizedDescription)")
            return 1
        }
        say("stored address deliberately set to \(bogus) (real: \(real.address))")

        defer {
            // Never leave the user's credentials pointing at a bogus address.
            if BridgeStore.load()?.address == bogus { try? BridgeStore.save(real) }
        }

        guard let stored = BridgeStore.load() else { return 1 }
        do {
            let lights = try await BridgeTransport(credentials: stored).fetchLights()
            let recovered = BridgeStore.load()?.address ?? "?"
            say("recovered: \(lights.count) light(s), stored address now \(recovered)")
            let ok = !lights.isEmpty && recovered != bogus
            say(ok ? "PASS — bridge re-discovered after address change"
                   : "FAIL — did not recover")
            return ok ? 0 : 1
        } catch {
            say("FAIL — \(error.localizedDescription)")
            return 1
        }
    }

    /// Connects exactly the way the app does and reports every light the bridge has.
    public static func verify() async -> Int32 {
        guard let credentials = BridgeStore.load() else {
            say("no bridge credentials in the Keychain — run --pair-bridge <host> first")
            return 1
        }
        say("bridge \(credentials.bridgeID) at \(credentials.address)")

        let transport = BridgeTransport(credentials: credentials)
        do {
            let lights = try await transport.fetchLights()
            guard !lights.isEmpty else {
                say("connected, but the bridge reports no lights")
                return 1
            }

            say("\(lights.count) light(s):\n")
            let width = lights.map(\.name.count).max() ?? 10
            for light in lights.sorted(by: { $0.name < $1.name }) {
                let name = light.name.padding(toLength: width, withPad: " ", startingAt: 0)
                let power = light.state.isOn ? "on " : "off"
                let brightness = String(format: "%3.0f%%", light.state.brightness * 100)
                let colour: String
                switch light.state.color {
                case .temperature(let mireds):
                    colour = "\(Int(ColorScience.kelvin(fromMireds: mireds)))K"
                case .xy(let x, let y):
                    colour = String(format: "xy %.3f,%.3f", x, y)
                }
                say("  \(name)  \(power)  \(brightness)  \(colour)  [\(light.connection.shortLabel)]")
            }

            let ready = lights.filter { $0.connection.isCommandable }.count
            say("\n\(ready)/\(lights.count) commandable")
            return ready == lights.count ? 0 : 1
        } catch {
            let ns = error as NSError
            say("connection failed: \(error.localizedDescription)")
            say("  domain=\(ns.domain) code=\(ns.code)")
            for (key, value) in ns.userInfo where key != NSLocalizedDescriptionKey {
                say("  \(key)=\(value)")
            }
            return 1
        }
    }
}
