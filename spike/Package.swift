// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "huescan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "huescan")
    ]
)
