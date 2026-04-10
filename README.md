# MixpanelOpenFeature

An [OpenFeature](https://openfeature.dev/) provider that wraps Mixpanel's feature flags for use with the OpenFeature Swift SDK. This allows you to use Mixpanel's feature flagging capabilities through OpenFeature's standardized, vendor-agnostic API.

## Overview

This package provides a bridge between Mixpanel's native feature flags implementation and the OpenFeature specification. By using this provider, you can:

- Leverage Mixpanel's powerful feature flag and experimentation platform
- Use OpenFeature's standardized API for flag evaluation
- Easily switch between feature flag providers without changing your application code
- Integrate with OpenFeature's ecosystem of tools and frameworks

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

## Quick Start

```swift
import Mixpanel
import MixpanelOpenFeature
import OpenFeature

// 1. Create and register the provider using the convenience initializer
let options = MixpanelOptions(token: "YOUR_PROJECT_TOKEN")
let provider = MixpanelOpenFeatureProvider(options: options)
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider)

// 2. Get a client and evaluate flags
let client = OpenFeatureAPI.shared.getClient()
let showNewFeature = client.getBooleanValue(key: "new-feature-flag", defaultValue: false)

if showNewFeature {
    print("New feature is enabled!")
}
```

Alternatively, if you already have a Mixpanel instance:

```swift
let flags = Mixpanel.mainInstance().flags
let provider = MixpanelOpenFeatureProvider(flags: flags)
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider)
```

> **Important:** This provider does **not** call `mixpanel.identify()` or `mixpanel.track()`. If you need to update the logged-in user or make use of [Runtime Events](https://docs.mixpanel.com/docs/feature-flags/runtime-events), you must call these methods directly on the **same Mixpanel instance** that was passed into the provider.
>
> When using `init(options:)`, access the underlying instance via the `mixpanel` property:
> ```swift
> provider.mixpanel?.identify(distinctId: "user-123")
> provider.mixpanel?.track(event: "Purchase", properties: ["amount": 49.99])
> ```
>
> When using `init(flags:)`, call `identify()` and `track()` on the original Mixpanel instance:
> ```swift
> let mixpanelInstance = Mixpanel.mainInstance()
> let provider = MixpanelOpenFeatureProvider(flags: mixpanelInstance.flags)
> // Use the same instance:
> mixpanelInstance.identify(distinctId: "user-123")
> mixpanelInstance.track(event: "Purchase", properties: ["amount": 49.99])
> ```
>
> Using a different Mixpanel instance for `identify()` or `track()` than the one backing the provider will not affect flag evaluation.

## Usage Examples

### Basic Boolean Flag

```swift
let client = OpenFeatureAPI.shared.getClient()

// Get a boolean flag with a default value
let isFeatureEnabled = client.getBooleanValue(key: "my-feature", defaultValue: false)

if isFeatureEnabled {
    // Show the new feature
}
```

### Mixpanel Flag Types and OpenFeature Evaluation Methods

Mixpanel feature flags support three flag types. Use the corresponding OpenFeature evaluation method based on your flag's variant values:

| Mixpanel Flag Type | Variant Values | OpenFeature Method |
|---|---|---|
| Feature Gate | `true` / `false` | `getBooleanValue()` |
| Experiment | boolean, string, number, or JSON object | `getBooleanValue()`, `getStringValue()`, `getIntegerValue()`, `getDoubleValue()`, or `getObjectValue()` |
| Dynamic Config | JSON object | `getObjectValue()` |

```swift
let client = OpenFeatureAPI.shared.getClient()

// Feature Gate - boolean variants
let isFeatureOn = client.getBooleanValue(key: "new-checkout", defaultValue: false)

// Experiment with string variants
let buttonColor = client.getStringValue(key: "button-color-test", defaultValue: "blue")

// Experiment with integer variants
let maxItems = client.getIntegerValue(key: "max-items", defaultValue: 10)

// Experiment with double variants
let threshold = client.getDoubleValue(key: "score-threshold", defaultValue: 0.5)

// Dynamic Config - JSON object variants
let featureConfig = client.getObjectValue(
    key: "homepage-layout",
    defaultValue: Value.structure(["layout": .string("grid"), "itemsPerRow": .integer(3)])
)
```

### Getting Full Resolution Details

If you need additional metadata about the flag evaluation:

```swift
let client = OpenFeatureAPI.shared.getClient()

let details = client.getBooleanDetails(key: "my-feature", defaultValue: false)

print(details.value)       // The resolved value
print(details.variant)     // The variant key from Mixpanel
print(details.reason)      // Why this value was returned
print(details.errorCode)   // Error code if evaluation failed
```

### Setting Context

You can pass evaluation context that will be sent to Mixpanel for flag evaluation using `OpenFeatureAPI.shared.setEvaluationContext()`:

```swift
let ctx = MutableContext(
    targetingKey: "user-123",
    structure: MutableStructure(attributes: [
        "email": .string("user@example.com"),
        "plan": .string("premium"),
    ])
)
await OpenFeatureAPI.shared.setEvaluationContext(evaluationContext: ctx)
```

### Using custom_properties for Runtime Properties

You can pass `custom_properties` in the evaluation context for use with Mixpanel's [Runtime Properties](https://docs.mixpanel.com/docs/feature-flags/runtime-properties) targeting rules. Values must be flat key-value pairs (no nested objects):

```swift
let ctx = MutableContext(
    structure: MutableStructure(attributes: [
        "custom_properties": .structure([
            "tier": .string("enterprise"),
            "seats": .integer(50),
            "industry": .string("technology"),
        ]),
    ])
)
await OpenFeatureAPI.shared.setEvaluationContext(evaluationContext: ctx)
```

## Context Mapping

### All Properties Passed Directly

All properties in the OpenFeature `EvaluationContext` are passed directly to Mixpanel's feature flag evaluation. There is no transformation or filtering of properties.

```swift
// This OpenFeature context...
let ctx = MutableContext(
    targetingKey: "user-123",
    structure: MutableStructure(attributes: [
        "email": .string("user@example.com"),
        "plan": .string("premium"),
        "beta_tester": .boolean(true),
    ])
)
await OpenFeatureAPI.shared.setEvaluationContext(evaluationContext: ctx)

// ...is passed to Mixpanel as-is for flag evaluation
```

### targetingKey is Not Special

Unlike some feature flag providers, `targetingKey` is **not** used as a special bucketing key in Mixpanel. It is simply passed as another context property. Mixpanel's server-side configuration determines which properties are used for:

- **Targeting rules**: Which users see which variants
- **Bucketing**: How users are consistently assigned to variants

## Error Handling

The provider uses OpenFeature's standard error codes to indicate issues during flag evaluation:

### PROVIDER_NOT_READY

Returned when flags are evaluated before the provider has finished initializing.

```swift
// To avoid this error, use setProviderAndWait
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider)
```

### FLAG_NOT_FOUND

Returned when the requested flag does not exist in Mixpanel.

```swift
let details = client.getBooleanDetails(key: "nonexistent-flag", defaultValue: false)

if details.errorCode == .flagNotFound {
    print("Flag does not exist, using default value")
}
```

### TYPE_MISMATCH

Returned when the flag value type does not match the requested type.

```swift
// If 'my-flag' is configured as a string in Mixpanel...
let details = client.getBooleanDetails(key: "my-flag", defaultValue: false)

if details.errorCode == .typeMismatch {
    print("Flag is not a boolean, using default value")
}
```

## Troubleshooting

### Flags Always Return Default Values

**Possible causes:**

1. **Provider not ready**: Make sure to wait for the provider to initialize:
   ```swift
   await OpenFeatureAPI.shared.setProviderAndWait(provider: provider)
   ```

2. **Network issues**: Check for failed requests to Mixpanel's flags API.

3. **Flag not configured**: Verify the flag exists in your Mixpanel project and is enabled.

### Type Mismatch Errors

If you are getting `TYPE_MISMATCH` errors:

1. **Check flag configuration**: Verify the flag's value type in Mixpanel matches how you are evaluating it:
   ```swift
   // If flag value is a string like "true", use getStringValue, not getBooleanValue
   let value = client.getStringValue(key: "my-flag", defaultValue: "default")
   ```

2. **Use getObjectValue for complex types**: For JSON objects or arrays, use `getObjectValue`.

### Flags Not Updating After Context Change

When you update the OpenFeature context, the provider needs to fetch new flag values:

```swift
// Update context and wait for new flags
let newCtx = MutableContext(
    structure: MutableStructure(attributes: ["plan": .string("premium")])
)
await OpenFeatureAPI.shared.setEvaluationContext(evaluationContext: newCtx)

// Now evaluate with new context
let value = client.getBooleanValue(key: "premium-feature", defaultValue: false)
```

If flags still are not updating, check that your targeting rules in Mixpanel are configured to use the context properties you are setting.

## License

Apache 2.0 -- see [LICENSE](LICENSE) for details.
