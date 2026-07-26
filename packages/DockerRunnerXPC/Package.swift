// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DockerRunnerXPC",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DockerRunnerXPC",
            targets: ["DockerRunnerXPC"]
        )
    ],
    targets: [
        .target(
            name: "DockerRunnerXPC",
            path: "Sources/DockerRunnerXPC"
        ),
        .testTarget(
            name: "DockerRunnerXPCTests",
            dependencies: ["DockerRunnerXPC"],
            path: "Tests/DockerRunnerXPCTests"
        )
    ]
)
