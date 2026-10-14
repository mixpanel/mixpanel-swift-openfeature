// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "MixpanelOpenFeature",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macOS(.v12),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "MixpanelOpenFeature", targets: ["MixpanelOpenFeature"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/mixpanel/mixpanel-swift",
            from: "7.0.0"
        ),
        .package(
            url: "https://github.com/open-feature/swift-sdk.git",
            from: "0.6.0"
        ),
    ],
    targets: [
        .target(
            name: "MixpanelOpenFeature",
            dependencies: [
                .product(name: "Mixpanel", package: "mixpanel-swift"),
                .product(name: "OpenFeature", package: "swift-sdk"),
            ],
            path: "Sources/MixpanelOpenFeature"
        ),
        .testTarget(
            name: "MixpanelOpenFeatureTests",
            dependencies: ["MixpanelOpenFeature"],
            path: "Tests/MixpanelOpenFeatureTests"
        ),
    ]
)
