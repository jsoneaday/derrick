// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Plugin",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Plugin",
            targets: ["Plugin"]
        ),
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "Plugin",
            dependencies: ["Structure"],
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "PluginTests",
            dependencies: ["Plugin", "Structure"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
