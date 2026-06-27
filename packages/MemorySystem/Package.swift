// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemorySystem",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "MemorySystem",
            targets: ["MemorySystem"]
        )
    ],
    targets: [
        .target(
            name: "MemorySystem",
            path: "Sources/MemorySystem",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MemorySystemTests",
            dependencies: ["MemorySystem"],
            path: "Tests/MemorySystemTests"
        )
    ]
)
