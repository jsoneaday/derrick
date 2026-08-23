// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCPServer",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "MCPServer",
            targets: ["MCPServer"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../MCPClient"),
        .package(path: "../LLMAgentClient"),
        .package(path: "../DockerRunnerXPC"),
        .package(path: "../EgressProxy"),
        .package(path: "../MCPToolCatalog"),
        .package(path: "../ServiceContracts"),
        .package(path: "../Plugin")
    ],
    targets: [
        .target(
            name: "MCPServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "MCPClient",
                "LLMAgentClient",
                "DockerRunnerXPC",
                "EgressProxy",
                "MCPToolCatalog",
                "ServiceContracts",
                "Plugin"
            ],
            path: "Sources/MCPServer"
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: ["MCPServer", "MCPClient", "DockerRunnerXPC"],
            path: "Tests/MCPServerTests"
        )
    ]
)
