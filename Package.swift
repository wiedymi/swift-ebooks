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
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "BookKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
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
