// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The SDK supplies Liquid Glass APIs; the deployment target specifies the oldest
// supported OS. Runtime availability checks allow one app to support both looks.
let deploymentTarget = ProcessInfo.processInfo.environment["VESTA_MACOS_TARGET"] ?? "14.0"

// Xcode 26 ships Swift 6.2 and the macOS 26 SDK. Older Xcode toolchains compile
// only the fallback. VESTA_CLASSIC exercises that path on a modern toolchain too.
#if compiler(>=6.2)
let glassSettings: [SwiftSetting] = ProcessInfo.processInfo.environment["VESTA_CLASSIC"] == "1"
    ? [] : [.define("VESTA_GLASS")]
#else
let glassSettings: [SwiftSetting] = []
#endif

let package = Package(
    name: "Vesta",
    platforms: [.macOS(deploymentTarget)],
    targets: [
        // Domain. Knows nothing about any particular protocol, and imports no UI.
        .target(name: "VestaKit"),
        .target(name: "VestaDesign", dependencies: ["VestaKit"], swiftSettings: glassSettings),

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
                dependencies: ["VestaKit", "VestaBLE", "VestaBridge", "VestaDiagnostics", "VestaDesign"],
                swiftSettings: glassSettings),

        // Composition root: argument dispatch and nothing else.
        .executableTarget(name: "Vesta", dependencies: ["VestaUI", "VestaCLI"],
                          swiftSettings: glassSettings),

        // A separate menu-bar app for Kasa. It shares Vesta's visual language,
        // but owns its discovery, account credentials, and device lifecycle.
        .target(name: "KasaKit"),
        .target(name: "KasaTransport", dependencies: ["KasaKit"]),
        .target(name: "KasaUI", dependencies: ["KasaKit", "KasaTransport", "VestaKit", "VestaDesign"],
                swiftSettings: glassSettings),
        .executableTarget(name: "VestaKasa", dependencies: ["KasaUI", "KasaTransport"]),
        .testTarget(name: "KasaTests", dependencies: ["KasaKit", "KasaTransport", "KasaUI", "VestaDesign"]),

        // Interactive layout exploration only: no transports or Keychain access.
        .target(name: "HomePreviewUI", dependencies: ["VestaDesign", "VestaKit"], swiftSettings: glassSettings),
        .executableTarget(name: "VestaHomePreview", dependencies: ["HomePreviewUI"]),
        .testTarget(name: "HomePreviewTests", dependencies: ["HomePreviewUI", "VestaDesign"]),

        // Opt-in combined app. Only this app links the Google cloud integration.
        .target(name: "NestCore", path: "nest/Sources/NestCore"),
        .target(name: "HomeUI", dependencies: ["VestaKit", "VestaDesign", "VestaBridge", "VestaUI", "KasaKit", "KasaUI", "NestCore"], swiftSettings: glassSettings),
        .executableTarget(name: "VestaHome", dependencies: ["HomeUI"]),
        .testTarget(name: "HomeTests", dependencies: ["HomeUI", "NestCore"]),

        .testTarget(name: "VestaKitTests", dependencies: ["VestaKit"]),
        .testTarget(name: "VestaBLETests", dependencies: ["VestaBLE"]),
        .testTarget(name: "VestaUITests", dependencies: ["VestaUI"]),
        .testTarget(name: "VestaBridgeTests", dependencies: ["VestaBridge", "VestaKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
