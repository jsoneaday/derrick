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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(
            name: "Lib",
            dependencies: [
                 .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/Lib"
        )
    ]
)
