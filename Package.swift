// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Liquid Glass is opted into by the deployment target, not by calling glassEffect:
// building against macOS 26 restyles the popover chrome and every standard control.
// A single binary therefore cannot show the new look on 26+ and the old one on 14 —
// the design language is fixed at build time. So the target is a build parameter and
// the entire source tree is shared between the two variants.
//
//   ./build.sh              → macOS 26 baseline, Liquid Glass
//   VESTA_MACOS_TARGET=14.0 ./build.sh  → macOS 14 baseline, classic appearance
let deploymentTarget = ProcessInfo.processInfo.environment["VESTA_MACOS_TARGET"] ?? "26.0"

// glassEffect exists only in the macOS 26 SDK. `if #available` is not enough: the
// symbol has to be present at compile time, so on an older Xcode the source would
// not build at all. Compiling the glass paths out keeps the tree buildable on any
// supported toolchain — and the classic variant genuinely does not need them.
let major = Int(deploymentTarget.split(separator: ".").first.map(String.init) ?? "") ?? 0
let glassSettings: [SwiftSetting] = major >= 26 ? [.define("VESTA_GLASS")] : []

let package = Package(
    name: "Vesta",
    platforms: [.macOS(deploymentTarget)],
    targets: [
        // Domain. Knows nothing about any particular protocol, and imports no UI.
        .target(name: "VestaKit"),

        // Transports. Each is the only place its framework may be imported.
        .target(name: "VestaBLE", dependencies: ["VestaKit"]),
        .target(name: "VestaBridge", dependencies: ["VestaKit"]),

        // The health report. Its own target because both the interface and the CLI
        // need it, and the CLI must not have to depend on the interface to get it.
        // glassSettings because Diagnostics reports which variant the binary is, and
        // VESTA_GLASS is defined per target: without it here the report said
        // "classic" for every build, including a Liquid Glass one.
        .target(name: "VestaDiagnostics", dependencies: ["VestaKit", "VestaBridge"],
                swiftSettings: glassSettings),

        // Command line modes: pairing, verification, hardware self-tests. No UI.
        .target(name: "VestaCLI",
                dependencies: ["VestaKit", "VestaBridge", "VestaDiagnostics"]),

        // The interface, and the offscreen renderer that photographs it.
        .target(name: "VestaUI",
                dependencies: ["VestaKit", "VestaBLE", "VestaBridge", "VestaDiagnostics"],
                swiftSettings: glassSettings),

        // Composition root: argument dispatch and nothing else.
        .executableTarget(name: "Vesta", dependencies: ["VestaUI", "VestaCLI"],
                          swiftSettings: glassSettings),

        .testTarget(name: "VestaKitTests", dependencies: ["VestaKit"]),
        .testTarget(name: "VestaBridgeTests", dependencies: ["VestaBridge", "VestaKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
