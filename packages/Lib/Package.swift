// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lib",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Lib",
            targets: ["Lib"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "Lib",
            dependencies: [
                "Structure",
            ],
            path: "Sources/Lib"
        ),
        .testTarget(
            name: "LibTests",
            dependencies: ["Lib", "Structure"],
            path: "Tests/LibTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
