// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemorySystem",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "MemorySystem",
            targets: ["MemorySystem"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "MemorySystem",
            dependencies: ["Structure"],
            path: "Sources/MemorySystem",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MemorySystemTests",
            dependencies: ["MemorySystem", "Structure"],
            path: "Tests/MemorySystemTests"
        )
    ]
)
