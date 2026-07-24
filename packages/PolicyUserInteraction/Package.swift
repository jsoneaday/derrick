// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PolicyUserInteraction",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PolicyUserInteraction", targets: ["PolicyUserInteraction"])
    ],
    dependencies: [
        .package(path: "../AppEvents")
    ],
    targets: [
        .target(
            name: "PolicyUserInteraction",
            dependencies: ["AppEvents"],
            path: "Sources/PolicyUserInteraction",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "PolicyUserInteractionTests",
            dependencies: ["PolicyUserInteraction", "AppEvents"],
            path: "Tests/PolicyUserInteractionTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
