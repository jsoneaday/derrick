// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DBRepository",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "DBRepository",
            targets: ["DBRepository"]
        )
    ],
    targets: [
        .target(
            name: "DBRepository",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "DBRepositoryTests",
            dependencies: ["DBRepository"]
        )
    ]
)
