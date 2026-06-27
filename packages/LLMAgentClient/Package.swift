// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LLMAgentClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "LLMAgentClient",
            targets: ["LLMAgentClient"]
        )
    ],
    dependencies: [
        .package(path: "../MemorySystem")
    ],
    targets: [
        .target(
            name: "LLMAgentClient",
            dependencies: ["MemorySystem"],
            path: "Sources/LLMAgentClient"
        ),
        .testTarget(
            name: "LLMAgentClientTests",
            dependencies: ["LLMAgentClient"],
            path: "Tests/LLMAgentClientTests"
        )
    ]
)
