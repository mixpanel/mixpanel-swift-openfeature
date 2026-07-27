import Combine
import Foundation
import Mixpanel
import OpenFeature

struct MixpanelProviderMetadata: ProviderMetadata {
    var name: String? = "mixpanel-provider"
}

public class MixpanelOpenFeatureProvider: FeatureProvider {
    private let flags: MixpanelFlags
    private let eventHandler = EventHandler()

    /// Outcome of a single flag resolution. `resolve()` dispatches on
    /// `MixpanelFlagVariant.source` to distinguish the three fallback reasons
    /// exposed by SDK-79 (flag missing vs flags not ready vs backend failure),
    /// mapping each to a specific OpenFeature error code instead of collapsing
    /// them all to `.flagNotFound` as the pre-SDK-79 wrapper did.
    private enum Resolution {
        case success(MixpanelFlagVariant)
        case error(errorCode: ErrorCode, reason: String)
    }

    /// The underlying Mixpanel instance, available when the provider was
    /// created via `init(options:)`. Use this to call `identify()`,
    /// `track()`, and other Mixpanel methods on the instance.
    public private(set) var mixpanel: MixpanelInstance?

    public var hooks: [any Hook] { [] }
    public var metadata: ProviderMetadata { MixpanelProviderMetadata() }

    /// Creates a provider backed by an existing ``MixpanelFlags`` instance.
    ///
    /// Use this initializer when you already have a Mixpanel instance and want
    /// to pass its `flags` property directly.
    ///
    /// - Parameter flags: The ``MixpanelFlags`` instance to use for flag evaluation.
    public init(flags: MixpanelFlags) {
        self.flags = flags
    }

    /// Creates a provider by initializing a new Mixpanel instance from the given options.
    ///
    /// The created `MixpanelInstance` is accessible via the ``mixpanel`` property
    /// so you can call `identify()`, `track()`, and other methods on it.
    ///
    /// - Parameter options: Configuration options for the Mixpanel SDK.
    public convenience init(options: MixpanelOptions) {
        let instance = Mixpanel.initialize(options: options)
        self.init(flags: instance.flags)
        self.mixpanel = instance
    }

    public func observe() -> AnyPublisher<ProviderEvent?, Never> {
        return eventHandler.observe()
    }

    public func initialize(initialContext: (any EvaluationContext)?) async throws {
        guard let context = initialContext else { return }
        let contextDict = Self.convertContext(context)
        await withCheckedContinuation { continuation in
            flags.setContext(contextDict) {
                continuation.resume()
            }
        }
    }

    public func onContextSet(
        oldContext: (any EvaluationContext)?, newContext: any EvaluationContext
    ) async throws {
        let contextDict = Self.convertContext(newContext)
        await withCheckedContinuation { continuation in
            flags.setContext(contextDict) {
                continuation.resume()
            }
        }
    }

    public func getBooleanEvaluation(
        key: String, defaultValue: Bool, context: (any EvaluationContext)?
    ) throws -> ProviderEvaluation<Bool> {
        let variant: MixpanelFlagVariant
        switch resolve(key) {
            case .error(let errorCode, let reason):
                return ProviderEvaluation(value: defaultValue, reason: reason, errorCode: errorCode)
            case .success(let v):
                variant = v
        }
        guard let boolValue = variant.value as? Bool else {
            return ProviderEvaluation(value: defaultValue, reason: "ERROR", errorCode: .typeMismatch)
        }
        return ProviderEvaluation(value: boolValue, variant: variant.key, reason: "TARGETING_MATCH")
    }

    public func getStringEvaluation(
        key: String, defaultValue: String, context: (any EvaluationContext)?
    ) throws -> ProviderEvaluation<String> {
        let variant: MixpanelFlagVariant
        switch resolve(key) {
            case .error(let errorCode, let reason):
                return ProviderEvaluation(value: defaultValue, reason: reason, errorCode: errorCode)
            case .success(let v):
                variant = v
        }
        guard let stringValue = variant.value as? String else {
            return ProviderEvaluation(value: defaultValue, reason: "ERROR", errorCode: .typeMismatch)
        }
        return ProviderEvaluation(value: stringValue, variant: variant.key, reason: "TARGETING_MATCH")
    }

    public func getIntegerEvaluation(
        key: String, defaultValue: Int64, context: (any EvaluationContext)?
    ) throws -> ProviderEvaluation<Int64> {
        let variant: MixpanelFlagVariant
        switch resolve(key) {
            case .error(let errorCode, let reason):
                return ProviderEvaluation(value: defaultValue, reason: reason, errorCode: errorCode)
            case .success(let v):
                variant = v
        }
        guard let intValue = toInt64(variant.value) else {
            return ProviderEvaluation(value: defaultValue, reason: "ERROR", errorCode: .typeMismatch)
        }
        return ProviderEvaluation(value: intValue, variant: variant.key, reason: "TARGETING_MATCH")
    }

    public func getDoubleEvaluation(
        key: String, defaultValue: Double, context: (any EvaluationContext)?
    ) throws -> ProviderEvaluation<Double> {
        let variant: MixpanelFlagVariant
        switch resolve(key) {
            case .error(let errorCode, let reason):
                return ProviderEvaluation(value: defaultValue, reason: reason, errorCode: errorCode)
            case .success(let v):
                variant = v
        }
        guard let doubleValue = toDouble(variant.value) else {
            return ProviderEvaluation(value: defaultValue, reason: "ERROR", errorCode: .typeMismatch)
        }
        return ProviderEvaluation(value: doubleValue, variant: variant.key, reason: "TARGETING_MATCH")
    }

    public func getObjectEvaluation(
        key: String, defaultValue: Value, context: (any EvaluationContext)?
    ) throws -> ProviderEvaluation<Value> {
        let variant: MixpanelFlagVariant
        switch resolve(key) {
            case .error(let errorCode, let reason):
                return ProviderEvaluation(value: defaultValue, reason: reason, errorCode: errorCode)
            case .success(let v):
                variant = v
        }
        let value = toValue(variant.value)
        return ProviderEvaluation(value: value, variant: variant.key, reason: "TARGETING_MATCH")
    }

    // MARK: - Private

    private static func convertContext(_ context: any EvaluationContext) -> [String: Any] {
        var dict: [String: Any] = context.asMap().mapValues { convertValue($0) }
        if !context.getTargetingKey().isEmpty {
            dict["targetingKey"] = context.getTargetingKey()
        }
        return dict
    }

    private static func convertValue(_ value: Value) -> Any {
        switch value {
            case .boolean(let v): return v
            case .string(let v): return v
            case .integer(let v): return v
            case .double(let v): return v
            case .date(let v): return v.timeIntervalSince1970
            case .list(let v): return v.map { convertValue($0) }
            case .structure(let v): return v.mapValues { convertValue($0) }
            case .null: return NSNull()
        }
    }

    private func resolve(_ key: String) -> Resolution {
        // Short-circuit before the sync call so callers who invoke pre-load get
        // `.providerNotReady` even if the underlying `getVariantSync` were to
        // hand back a `.fallback(reason: .flagNotFound)` (e.g. against a mock
        // that doesn't stamp `.notReady`). Base SDK also stamps `.notReady` on
        // its own fallback in this case — the switch below catches that too.
        guard flags.areFlagsReady() else {
            return .error(errorCode: .providerNotReady, reason: "ERROR")
        }

        // Pass a plain fallback; the base SDK re-stamps it with the concrete
        // `Source.fallback(reason:)` reason when it can't serve a real variant.
        let fallback = MixpanelFlagVariant(key: "")
        let variant = flags.getVariantSync(key, fallback: fallback)

        if case .fallback(let reason) = variant.source {
            switch reason {
                case .flagNotFound:
                    return .error(errorCode: .flagNotFound, reason: "DEFAULT")
                case .notReady:
                    return .error(errorCode: .providerNotReady, reason: "ERROR")
                case .backendError:
                    return .error(errorCode: .general, reason: "ERROR")
                // Fail closed on unrecognized reasons so a new case added to the base
                // SDK's FallbackReason enum doesn't source-break this wrapper on
                // recompile. `@unknown default` also nudges the compiler to warn when
                // a new case is added, prompting explicit handling.
                @unknown default:
                    return .error(errorCode: .general, reason: "ERROR")
            }
        }
        return .success(variant)
    }

    private func toInt64(_ value: Any?) -> Int64? {
        switch value {
            case let v as Int: return Int64(v)
            case let v as Int64: return v
            case let v as Int32: return Int64(v)
            case let v as Double: return Int64(exactly: v)
            case let v as Float: return Int64(exactly: v)
            default: return nil
        }
    }

    private func toDouble(_ value: Any?) -> Double? {
        switch value {
            case let v as Double: return v
            case let v as Float: return Double(v)
            case let v as Int: return Double(v)
            case let v as Int64: return Double(v)
            case let v as Int32: return Double(v)
            default: return nil
        }
    }

    private func toValue(_ value: Any?) -> Value {
        switch value {
            case nil:
                return .null
            case let v as Bool:
                return .boolean(v)
            case let v as String:
                return .string(v)
            case let v as Int:
                return .integer(Int64(v))
            case let v as Int64:
                return .integer(v)
            case let v as Double:
                return .double(v)
            case let v as [Any?]:
                return .list(v.map { toValue($0) })
            case let v as [Any]:
                return .list(v.map { toValue($0) })
            case let v as [String: Any?]:
                return .structure(v.mapValues { toValue($0) })
            case let v as [String: Any]:
                return .structure(v.mapValues { toValue($0) })
            case let v as NSArray:
                return .list(v.map { toValue($0) })
            case let v as NSDictionary:
                var mapped: [String: Value] = [:]
                for (key, value) in v {
                    if let key = key as? String {
                        mapped[key] = toValue(value)
                    }
                }
                return .structure(mapped)
            default:
                return .null
        }
    }
}
