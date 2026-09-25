// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BookKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "BookKit", targets: ["BookKit"]),
        .executable(name: "BookKitExample", targets: ["BookKitExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vivy-company/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "BookKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .testTarget(
            name: "BookKitTests",
            dependencies: [
                "BookKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "tests/BookKitTests"
        ),
        .executableTarget(
            name: "BookKitExample",
            dependencies: ["BookKit"],
            path: "Examples/BookKitExample"
        ),
    ]
)
