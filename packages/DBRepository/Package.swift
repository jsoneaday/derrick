// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DBRepository",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "DBRepository",
            targets: ["DBRepository"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
        .package(path: "../MemorySystem"),
        .package(path: "../AgentRuntime"),
        .package(path: "../Plugin"),
    ],
    targets: [
        .target(
            name: "DBRepository",
            dependencies: ["Structure", "MemorySystem", "AgentRuntime", "Plugin"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "DBRepositoryTests",
            dependencies: ["DBRepository", "Plugin", "Structure"]
        )
    ]
)
