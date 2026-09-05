// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AppEvents",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AppEvents", targets: ["AppEvents"])
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "AppEvents",
            dependencies: ["Structure"],
            path: "Sources/AppEvents",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "AppEventsTests",
            dependencies: ["AppEvents", "Structure"],
            path: "Tests/AppEventsTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
