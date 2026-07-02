// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lib",
    products: [
        .library(
            name: "Lib",
            targets: ["Lib"]
        )
    ],
    targets: [
        .target(
            name: "Lib",
            path: "Sources/Lib"
        )
    ]
)
