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
        // Domain model + the transport seam. Knows nothing about Bluetooth,
        // so it stays testable and buildable regardless of the bonding situation.
        .target(name: "VestaKit"),

        // The only target that imports CoreBluetooth.
        .target(name: "VestaBLE", dependencies: ["VestaKit"]),

        // Hue Bridge over the local CLIP v2 API. Same LightTransport seam as
        // VestaBLE, so nothing above it knows which one is in use.
        .target(name: "VestaBridge", dependencies: ["VestaKit"]),

        .executableTarget(name: "Vesta", dependencies: ["VestaKit", "VestaBLE", "VestaBridge"],
                          swiftSettings: glassSettings),

        .testTarget(name: "VestaKitTests", dependencies: ["VestaKit"]),
        .testTarget(name: "VestaBridgeTests", dependencies: ["VestaBridge", "VestaKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
