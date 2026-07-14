// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PolicyEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "PolicyEngine",
            targets: ["PolicyEngine"]
        )
    ],
    targets: [
        .target(
            name: "PolicyEngine",
            path: "Sources/PolicyEngine"
        ),
        .testTarget(
            name: "PolicyEngineTests",
            dependencies: ["PolicyEngine"],
            path: "Tests/PolicyEngineTests"
        )
    ]
)
