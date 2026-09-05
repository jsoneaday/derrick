// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Selenops",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "Selenops",
            targets: ["Selenops"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            from: "2.13.5"
        )
    ],
    targets: [
        .target(
            name: "Selenops",
            dependencies: [
                "Structure",
                .product(name: "SwiftSoup", package: "swiftsoup")
            ],
            path: "Sources/Selenops",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ]
)
