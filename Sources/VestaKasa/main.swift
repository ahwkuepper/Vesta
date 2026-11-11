// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import KasaUI
import KasaTransport

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--snapshot-schedules"), arguments.indices.contains(index + 1) {
    Task {
        do { try await KasaSnapshot.renderSchedules(to: URL(fileURLWithPath: arguments[index + 1])); exit(0) }
        catch { FileHandle.standardError.write(Data("Could not render schedule previews.\n".utf8)); exit(1) }
    }
    RunLoop.main.run()
} else if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
    do { try KasaSnapshot.render(to: URL(fileURLWithPath: arguments[index + 1])) }
    catch { FileHandle.standardError.write(Data("Could not render the preview.\n".utf8)); exit(1) }
} else if arguments.contains("--check-schedules") {
    // Read only. Report capability/counts without device names, IDs or addresses.
    Task {
        do {
            let credentials = try KasaKeychain.load()
            let client = KasaClient()
            let discovered = try await client.discover()
            var checked = 0
            for base in discovered {
                do {
                    for device in try await client.read(base, credentials: credentials) {
                        let schedules = try await client.schedules(device, credentials: credentials)
                        print("\(device.model): \(schedules.rules.count) rules; \(schedules.rules.filter(\.editable).count) editable; clock readable: \(schedules.clock != nil); clock differs: \(schedules.clock?.differsFromMac() ?? false)")
                        checked += 1
                    }
                } catch { print("\(base.model): \(error.localizedDescription)") }
            }
            print("Schedule reads completed: \(checked)")
            exit(checked == 0 ? 1 : 0)
        } catch { print("Schedule check failed: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if arguments.contains("--discover") {
    // Read-only local verification. Names are deliberately omitted from stdout.
    Task {
        do {
            let client = KasaClient()
            let devices = try await client.discover()
            print("Found \(devices.count) Kasa devices")
            for device in devices {
                do {
                    let result = try await client.read(device, credentials: nil)
                    print("\(device.model): \(device.transport.rawValue), \(result.count) device(s), readable")
                } catch { print("\(device.model): \(device.transport.rawValue), \(device.connection.rawValue)") }
            }
            exit(devices.isEmpty ? 1 : 0)
        } catch { print("Discovery failed: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else {
    KasaApp.run()
}
