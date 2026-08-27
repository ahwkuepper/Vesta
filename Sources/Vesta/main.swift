import Foundation
import SwiftUI
import VestaCLI
import VestaUI

/// Entry point. CLI modes are dispatched here, before SwiftUI takes over the
/// process, because `App.init()` runs on the main thread with a guarded stack —
/// blocking it on a semaphore there overflows the guard region and crashes.
///
/// Async CLI work is driven by pumping the run loop rather than blocking it, so
/// URLSession delegate callbacks and TCC prompts can still be serviced.
private func runCLI(_ work: @escaping @Sendable () async -> Int32) -> Never {
    nonisolated(unsafe) var finished = false
    nonisolated(unsafe) var code: Int32 = 1

    Task.detached {
        code = await work()
        finished = true
    }
    while !finished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(code)
}

let arguments = CommandLine.arguments

if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    let directory = URL(fileURLWithPath: arguments[i + 1])
    runCLI {
        do {
            try await Snapshot.renderAll(to: directory)
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("snapshot failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

if let i = arguments.firstIndex(of: "--pair-bridge"), i + 1 < arguments.count {
    let host = arguments[i + 1]
    runCLI { await BridgeCLI.pair(host: host) }
}

if let i = arguments.firstIndex(of: "--test-scene-switch"), i + 2 < arguments.count {
    let a = arguments[i + 1], b = arguments[i + 2]
    runCLI { await BridgeCLI.testSceneSwitch(a, b) }
}

if let i = arguments.firstIndex(of: "--watch-events"), i + 1 < arguments.count {
    let name = arguments[i + 1]
    runCLI { await BridgeCLI.watchEvents(sceneName: name) }
}

if arguments.contains("--rebind-keychain") {
    runCLI { await BridgeCLI.rebindKeychain() }
}

if let i = arguments.firstIndex(of: "--recall"), i + 1 < arguments.count {
    let name = arguments[i + 1]
    runCLI { await BridgeCLI.recall(sceneName: name) }
}

if let i = arguments.firstIndex(of: "--make-presets"), i + 1 < arguments.count {
    let room = arguments[i + 1]
    runCLI { await BridgeCLI.makePresets(room: room) }
}

if arguments.contains("--test-gradient") {
    runCLI { await BridgeCLI.testGradient() }
}

if arguments.contains("--test-scenes") {
    runCLI { await BridgeCLI.testScenes() }
}

if let i = arguments.firstIndex(of: "--dump"), i + 1 < arguments.count {
    let type = arguments[i + 1]
    runCLI { await BridgeCLI.dump(type) }
}

if arguments.contains("--diagnose") {
    runCLI { await BridgeCLI.diagnose() }
}

if arguments.contains("--discover") {
    runCLI { await BridgeCLI.discover() }
}

if let i = arguments.firstIndex(of: "--test-relocate"), i + 1 < arguments.count {
    let bogus = arguments[i + 1]
    runCLI { await BridgeCLI.testRelocate(bogus: bogus) }
}

if arguments.contains("--test-lights") {
    runCLI { await BridgeCLI.testLights() }
}

if arguments.contains("--verify-bridge") {
    runCLI { await BridgeCLI.verify() }
}

VestaApp.run()
