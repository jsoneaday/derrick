// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCPToolCatalog",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MCPToolCatalog",
            targets: ["MCPToolCatalog"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "MCPToolCatalog",
            dependencies: ["Structure"]
        ),
        .testTarget(
            name: "MCPToolCatalogTests",
            dependencies: ["MCPToolCatalog", "Structure"],
            path: "Tests/MCPToolCatalogTests"
        )
    ]
)
