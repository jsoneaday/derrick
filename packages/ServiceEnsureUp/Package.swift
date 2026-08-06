// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ServiceEnsureUp",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ServiceEnsureUp", targets: ["ServiceEnsureUp"])
    ],
    dependencies: [
        .package(path: "../ServiceContracts"),
        .package(path: "../DockerRunnerXPC")
    ],
    targets: [
        .target(
            name: "ServiceEnsureUp",
            dependencies: [
                "ServiceContracts",
                "DockerRunnerXPC"
            ],
            path: "Sources/ServiceEnsureUp",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "ServiceEnsureUpTests",
            dependencies: ["ServiceEnsureUp"],
            path: "Tests/ServiceEnsureUpTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
