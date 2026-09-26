// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DerrickBackend",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DerrickBackend", targets: ["DerrickBackend"])
    ],
    dependencies: [
        .package(path: "../Structure"),
        .package(path: "../DBRepository"),
        .package(path: "../DockerRunnerXPC"),
        .package(path: "../Plugin"),
        .package(path: "../PolicyRuntime"),
    ],
    targets: [
        .target(
            name: "DerrickBackend",
            dependencies: [
                "Structure",
                "DBRepository",
                "DockerRunnerXPC",
                "Plugin",
                "PolicyRuntime",
            ],
            path: "Sources/DerrickBackend",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "DerrickBackendTests",
            dependencies: ["DerrickBackend", "DBRepository", "Plugin", "Structure", "PolicyRuntime"],
            path: "Tests/DerrickBackendTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
