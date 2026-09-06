// swift-tools-version: 6.2

import Foundation
import PackageDescription

/// Architecture map for Derrick: public types, protocols, and wire contracts only.
/// Implementations live in their respective service and package targets.
///
/// The web-crawler Docker image compiles this package on Linux. Linux must only
/// see `Sources/WebCrawler` (Foundation wire types). Apple-only modules such as
/// CryptoKit live in the other folders and cannot be part of that image.
#if os(Linux)
private let structureExclude: [String] = {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: sources.path),
          !names.isEmpty
    else {
        fatalError("Structure Package.swift could not list Sources/ for the Linux crawler image.")
    }
    let excluded = names
        .filter { $0 != "WebCrawler" && !$0.hasPrefix(".") }
        .sorted()
    guard excluded.contains("AppLayerServices") else {
        fatalError("Linux Structure exclude list must drop AppLayerServices (CryptoKit).")
    }
    return excluded
}()
private let structureDependencies: [Target.Dependency] = []
private let structureResources: [Resource] = []
private let structurePackageDependencies: [Package.Dependency] = []
#else
private let structureExclude: [String] = []
private let structureDependencies: [Target.Dependency] = [
    .product(name: "MCP", package: "swift-sdk"),
]
private let structureResources: [Resource] = [
    .copy("Contract/Resources/schemas"),
    .copy("Contract/Resources/contracts"),
]
private let structurePackageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
]
#endif

let package = Package(
    name: "Structure",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Structure",
            targets: ["Structure"]
        ),
    ],
    dependencies: structurePackageDependencies,
    targets: [
        .target(
            name: "Structure",
            dependencies: structureDependencies,
            path: "Sources",
            exclude: structureExclude,
            resources: structureResources,
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "StructureTests",
            dependencies: ["Structure"],
            path: "Tests/StructureTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
