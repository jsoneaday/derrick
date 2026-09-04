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
        .package(path: "../ServiceContracts"),
        .package(path: "../DBRepository"),
        .package(path: "../DockerRunnerXPC"),
        .package(path: "../Plugin")
    ],
    targets: [
        .target(
            name: "DerrickBackend",
            dependencies: [
                "ServiceContracts",
                "DBRepository",
                "DockerRunnerXPC",
                "Plugin"
            ],
            path: "Sources/DerrickBackend",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "DerrickBackendTests",
            dependencies: ["DerrickBackend", "DBRepository", "Plugin", "ServiceContracts"],
            path: "Tests/DerrickBackendTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
