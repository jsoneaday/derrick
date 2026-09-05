// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WebCrawler",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "WebCrawler",
            targets: ["WebCrawler"]
        ),
        .executable(
            name: "derrick-web-crawler",
            targets: ["derrick-web-crawler"]
        )
    ],
    dependencies: [
        .package(path: "../Structure"),
        .package(
            path: "../Selenops"
        ),
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            from: "1.34.0"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            from: "2.13.5"
        )
    ],
    targets: [
        .target(
            name: "WebCrawler",
            dependencies: [
                "Structure",
                .product(name: "Selenops", package: "selenops"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "SwiftSoup", package: "swiftsoup")
            ],
            path: "Sources/WebCrawler",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .executableTarget(
            name: "derrick-web-crawler",
            dependencies: ["WebCrawler"],
            path: "Sources/derrick-web-crawler",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "WebCrawlerTests",
            dependencies: ["WebCrawler", "Structure"],
            path: "Tests/WebCrawlerTests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ]
)
