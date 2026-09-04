// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DockerRunnerXPC",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "DockerRunnerXPC",
            targets: ["DockerRunnerXPC"]
        )
    ],
    dependencies: [
        .package(path: "../ServiceContracts"),
    ],
    targets: [
        .target(
            name: "DockerRunnerXPC",
            dependencies: ["ServiceContracts"],
            path: "Sources/DockerRunnerXPC"
        ),
        .testTarget(
            name: "DockerRunnerXPCTests",
            dependencies: ["DockerRunnerXPC", "ServiceContracts"],
            path: "Tests/DockerRunnerXPCTests"
        )
    ]
)
