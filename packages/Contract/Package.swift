// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Contract",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Contract",
            targets: ["Contract"]
        ),
    ],
    targets: [
        .target(
            name: "Contract",
            resources: [
                .copy("Resources/schemas"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "ContractTests",
            dependencies: ["Contract"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
