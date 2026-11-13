// swift-tools-version: 6.0
import PackageDescription

// An opt-in cloud companion; neither Vesta application links this package.
let package = Package(
    name: "NestReader",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "nest-reader", targets: ["NestReader"])],
    targets: [
        .target(name: "NestCore"),
        .executableTarget(name: "NestReader", dependencies: ["NestCore"]),
        .testTarget(name: "NestCoreTests", dependencies: ["NestCore"])
    ]
)
