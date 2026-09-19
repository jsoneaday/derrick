// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HostUI",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "HostUI", targets: ["HostUI"])
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "HostUI",
            dependencies: ["Structure"],
            path: "Sources/HostUI",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "HostUITests",
            dependencies: ["HostUI", "Structure"],
            path: "Tests/HostUITests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
