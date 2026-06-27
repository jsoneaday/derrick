// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCPClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "MCPClient",
            targets: ["MCPClient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(
            name: "MCPClient",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/MCPClient"
        ),
        .testTarget(
            name: "MCPClientTests",
            dependencies: ["MCPClient"],
            path: "Tests/MCPClientTests"
        )
    ]
)
