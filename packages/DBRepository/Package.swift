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
        .package(path: "../MemorySystem"),
        .package(path: "../AgentRuntime"),
        .package(path: "../ServiceContracts"),
        .package(path: "../Plugin")
    ],
    targets: [
        .target(
            name: "DBRepository",
            dependencies: ["MemorySystem", "AgentRuntime", "ServiceContracts", "Plugin"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "DBRepositoryTests",
            dependencies: ["DBRepository", "Plugin", "ServiceContracts"]
        )
    ]
)
