// swift-tools-version: 6.2

import PackageDescription

/// Architecture map for Derrick: public types, protocols, and wire contracts only.
/// Implementations live in their respective service and package targets.
let package = Package(
    name: "Structure",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Structure",
            targets: ["Structure"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "Structure",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources",
            resources: [
                .copy("Contract/Resources/schemas"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "StructureTests",
            dependencies: ["Structure"],
            path: "Tests/StructureTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
