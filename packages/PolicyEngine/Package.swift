// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PolicyEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "PolicyEngine",
            targets: ["PolicyEngine"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
        .package(path: "../MemorySystem"),
    ],
    targets: [
        .target(
            name: "PolicyEngine",
            dependencies: ["Structure", "MemorySystem"],
            path: "Sources/PolicyEngine"
        ),
        .testTarget(
            name: "PolicyEngineTests",
            dependencies: ["PolicyEngine", "Structure"],
            path: "Tests/PolicyEngineTests"
        )
    ]
)
