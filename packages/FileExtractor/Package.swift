// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FileExtractor",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "FileExtractor",
            targets: ["FileExtractor"]
        ),
        .executable(
            name: "derrick-file-extractor",
            targets: ["derrick-file-extractor"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
    ],
    targets: [
        .target(
            name: "FileExtractor",
            dependencies: ["Structure"],
            path: "Sources/FileExtractor",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .executableTarget(
            name: "derrick-file-extractor",
            dependencies: ["FileExtractor"],
            path: "Sources/derrick-file-extractor",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "FileExtractorTests",
            dependencies: ["FileExtractor", "Structure"],
            path: "Tests/FileExtractorTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ]
)
