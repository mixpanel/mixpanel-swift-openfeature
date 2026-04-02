# MixpanelOpenFeature

An [OpenFeature](https://openfeature.dev/) provider for [Mixpanel](https://mixpanel.com/) feature flags in Swift.

## Requirements

- iOS 14.0+ / tvOS 14.0+ / macOS 11.0+ / watchOS 7.0+
- Swift 5.5+

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mixpanel/mixpanel-swift-openfeature", from: "0.1.0"),
]
```

Then add `MixpanelOpenFeature` as a dependency of your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MixpanelOpenFeature", package: "mixpanel-swift-openfeature"),
    ]
),
```

## Usage

```swift
import Mixpanel
import MixpanelOpenFeature
import OpenFeature

// Get the flags interface from your Mixpanel instance
let flags = Mixpanel.mainInstance().flags

// Create and register the provider
let provider = MixpanelOpenFeatureProvider(flags: flags)
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider)

// Use OpenFeature to evaluate flags
let client = OpenFeatureAPI.shared.getClient()
let isEnabled = client.getBooleanValue(key: "my-feature", defaultValue: false)
```

## License

Apache 2.0 -- see [LICENSE](LICENSE) for details.
