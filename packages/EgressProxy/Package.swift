// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EgressProxy",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "EgressProxy",
            targets: ["EgressProxy"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "EgressProxy",
            dependencies: ["Structure"],
            path: "Sources/EgressProxy",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "EgressProxyTests",
            dependencies: ["EgressProxy", "Structure"],
            path: "Tests/EgressProxyTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
