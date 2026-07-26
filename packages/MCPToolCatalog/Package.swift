// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCPToolCatalog",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MCPToolCatalog",
            targets: ["MCPToolCatalog"]
        )
    ],
    targets: [
        .target(
            name: "MCPToolCatalog",
            path: "Sources/MCPToolCatalog"
        ),
        .testTarget(
            name: "MCPToolCatalogTests",
            dependencies: ["MCPToolCatalog"],
            path: "Tests/MCPToolCatalogTests"
        )
    ]
)
