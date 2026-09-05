// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentRuntime",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentRuntime", targets: ["AgentRuntime"])
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "AgentRuntime",
            dependencies: ["Structure"],
            path: "Sources/AgentRuntime",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "Structure"],
            path: "Tests/AgentRuntimeTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
