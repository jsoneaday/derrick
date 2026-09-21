// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCPServer",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "MCPServer",
            targets: ["MCPServer"]
        ),
        .library(
            name: "FactoryHarnessSupport",
            targets: ["FactoryHarnessSupport"]
        ),
        .executable(
            name: "FactoryHarness",
            targets: ["FactoryHarness"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../Structure"),
        .package(path: "../MCPClient"),
        .package(path: "../LLMAgentClient"),
        .package(path: "../DockerRunnerXPC"),
        .package(path: "../EgressProxy"),
        .package(path: "../Plugin"),
        .package(path: "../WebCrawler"),
        .package(path: "../DBRepository"),
    ],
    targets: [
        .target(
            name: "MCPServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "Structure",
                "MCPClient",
                "LLMAgentClient",
                "DockerRunnerXPC",
                "EgressProxy",
                "Plugin",
                "WebCrawler",
            ],
            path: "Sources/MCPServer"
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: ["MCPServer", "MCPClient", "DockerRunnerXPC", "WebCrawler", "Structure"],
            path: "Tests/MCPServerTests"
        ),
        .target(
            name: "FactoryHarnessSupport",
            dependencies: [
                "MCPServer",
                "Plugin",
                "LLMAgentClient",
                "Structure",
                "DBRepository",
            ],
            path: "Sources/FactoryHarnessSupport"
        ),
        .executableTarget(
            name: "FactoryHarness",
            dependencies: [
                "FactoryHarnessSupport",
                "MCPServer",
                "Plugin",
                "LLMAgentClient",
                "Structure",
                "DBRepository",
            ],
            path: "Sources/FactoryHarness"
        ),
    ]
)
