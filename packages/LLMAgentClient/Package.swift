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
        .package(path: "../MemorySystem"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(
            name: "LLMAgentClient",
            dependencies: [
                "MemorySystem",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/LLMAgentClient"
        ),
        .testTarget(
            name: "LLMAgentClientTests",
            dependencies: ["LLMAgentClient"],
            path: "Tests/LLMAgentClientTests"
        )
    ]
)
