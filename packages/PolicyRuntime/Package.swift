// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PolicyRuntime",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "PolicyRuntime",
            targets: ["PolicyRuntime"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
        .package(path: "../MemorySystem"),
    ],
    targets: [
        .target(
            name: "PolicyRuntime",
            dependencies: [
                "Structure",
                "MemorySystem",
            ],
            path: "Sources/PolicyRuntime"
        ),
        .testTarget(
            name: "PolicyRuntimeTests",
            dependencies: [
                "PolicyRuntime",
                "MemorySystem",
                "Structure",
            ],
            path: "Tests/PolicyRuntimeTests"
        )
    ]
)
