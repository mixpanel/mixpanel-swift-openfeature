// swift-tools-version:5.5

import PackageDescription

let package = Package(
  name: "MixpanelOpenFeature",
  platforms: [
    .iOS(.v14),
    .tvOS(.v14),
    .macOS(.v11),
    .watchOS(.v7),
  ],
  products: [
    .library(name: "MixpanelOpenFeature", targets: ["MixpanelOpenFeature"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/mixpanel/mixpanel-swift",
      from: "6.2.0"
    ),
    .package(
      name: "OpenFeature",
      url: "https://github.com/open-feature/swift-sdk.git",
      from: "0.5.0"
    ),
  ],
  targets: [
    .target(
      name: "MixpanelOpenFeature",
      dependencies: [
        .product(name: "Mixpanel", package: "mixpanel-swift"),
        .product(name: "OpenFeature", package: "OpenFeature"),
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
