// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ServiceContracts",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ServiceContracts", targets: ["ServiceContracts"])
    ],
    targets: [
        .target(
            name: "ServiceContracts",
            path: "Sources/ServiceContracts",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "ServiceContractsTests",
            dependencies: ["ServiceContracts"],
            path: "Tests/ServiceContractsTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
