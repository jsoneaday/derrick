// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DBRepository",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "DBRepository",
            targets: ["DBRepository"]
        )
    ],
    dependencies: [
        .package(path: "../MemorySystem")
    ],
    targets: [
        .target(
            name: "DBRepository",
            dependencies: ["MemorySystem"],
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "DBRepositoryTests",
            dependencies: ["DBRepository"]
        )
    ]
)
