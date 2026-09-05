// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCPClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "MCPClient",
            targets: ["MCPClient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../Structure"),
        .package(path: "../MCPToolCatalog"),
    ],
    targets: [
        .target(
            name: "MCPClient",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "Structure",
                "MCPToolCatalog",
            ],
            path: "Sources/MCPClient",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "MCPClientTests",
            dependencies: ["MCPClient", "Structure"],
            path: "Tests/MCPClientTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
