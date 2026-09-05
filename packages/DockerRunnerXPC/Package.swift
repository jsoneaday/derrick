// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DockerRunnerXPC",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DockerRunnerXPC", targets: ["DockerRunnerXPC"])
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "DockerRunnerXPC",
            dependencies: ["Structure"],
            path: "Sources/DockerRunnerXPC"
        ),
        .testTarget(
            name: "DockerRunnerXPCTests",
            dependencies: ["DockerRunnerXPC", "Structure"],
            path: "Tests/DockerRunnerXPCTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
