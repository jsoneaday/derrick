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
    targets: [
        .target(
            name: "AppEvents",
            path: "Sources/AppEvents",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "AppEventsTests",
            dependencies: ["AppEvents"],
            path: "Tests/AppEventsTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
