// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PolicyRuntime",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PolicyRuntime",
            targets: ["PolicyRuntime"]
        )
    ],
    dependencies: [
        .package(path: "../MemorySystem")
    ],
    targets: [
        .target(
            name: "PolicyRuntime",
            dependencies: [
                "MemorySystem"
            ],
            path: "Sources/PolicyRuntime"
        ),
        .testTarget(
            name: "PolicyRuntimeTests",
            dependencies: [
                "PolicyRuntime",
                "MemorySystem"
            ],
            path: "Tests/PolicyRuntimeTests"
        )
    ]
)
