import Combine
import Mixpanel
import OpenFeature
import XCTest

@testable import MixpanelOpenFeature

// MARK: - Mock

class MockMixpanelFlags: MixpanelFlags {
    var delegate: MixpanelFlagDelegate?

    var variants: [String: MixpanelFlagVariant] = [:]
    var ready: Bool = true
    var lastSetContext: [String: Any]?
    var loadFlagsCallCount = 0

    /// Per-key override for `MixpanelFlagVariant.Source`. When set, the mock
    /// stamps the specified source on the returned variant (or the fallback,
    /// if no `variants[flagName]` entry exists). Used by the SDK-79 wrapper
    /// tests to simulate `.notReady` and `.backendError` fallbacks that the
    /// base SDK produces internally.
    var variantSources: [String: MixpanelFlagVariant.Source] = [:]

    func loadFlags() {}

    func loadFlags(completion: ((Bool) -> Void)?) {
        loadFlagsCallCount += 1
        completion?(ready)
    }

    func setContext(_ context: [String: Any], completion: @escaping () -> Void) {
        lastSetContext = context
        completion()
    }

    func areFlagsReady() -> Bool { ready }

    func getVariantSync(_ flagName: String, fallback: MixpanelFlagVariant) -> MixpanelFlagVariant {
        // Mirror the base SDK's stamping behavior: found variants come back as
        // `.network`; missing keys come back as `.fallback(reason: .flagNotFound)`.
        // Tests can override the stamp per key via `variantSources`.
        if let source = variantSources[flagName] {
            let base = variants[flagName] ?? fallback
            return base.withSource(source)
        }
        if let existing = variants[flagName] {
            return existing.withSource(.network)
        }
        return fallback.withSource(.fallback(reason: .flagNotFound))
    }

    func getVariant(
        _ flagName: String, fallback: MixpanelFlagVariant,
        completion: @escaping (MixpanelFlagVariant) -> Void
    ) {
        completion(getVariantSync(flagName, fallback: fallback))
    }

    func getVariantValueSync(_ flagName: String, fallbackValue: Any?) -> Any? {
        return getVariantSync(flagName, fallback: MixpanelFlagVariant(value: fallbackValue)).value
    }

    func getVariantValue(
        _ flagName: String, fallbackValue: Any?, completion: @escaping (Any?) -> Void
    ) {
        completion(getVariantValueSync(flagName, fallbackValue: fallbackValue))
    }

    func isEnabledSync(_ flagName: String, fallbackValue: Bool) -> Bool {
        return getVariantValueSync(flagName, fallbackValue: fallbackValue) as? Bool ?? fallbackValue
    }

    func isEnabled(_ flagName: String, fallbackValue: Bool, completion: @escaping (Bool) -> Void) {
        completion(isEnabledSync(flagName, fallbackValue: fallbackValue))
    }

    func getAllVariantsSync() -> [String: MixpanelFlagVariant] {
        return variants
    }

    func getAllVariants(completion: @escaping ([String: MixpanelFlagVariant]) -> Void) {
        completion(variants)
    }
}

/// Holds `setContext` / `loadFlags(completion:)` callbacks until `releasePending()` is called,
/// so tests can observe provider state while a flag load is still in flight.
final class HeldCallbackMockFlags: MockMixpanelFlags {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    var holdCallbacks = true

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    private func hold(_ callback: @escaping () -> Void) {
        guard holdCallbacks else { return callback() }
        lock.lock()
        pending.append(callback)
        lock.unlock()
    }

    override func loadFlags(completion: ((Bool) -> Void)?) {
        loadFlagsCallCount += 1
        hold { completion?(self.ready) }
    }

    override func setContext(_ context: [String: Any], completion: @escaping () -> Void) {
        lastSetContext = context
        hold(completion)
    }

    /// Runs every held callback, in the order it was received.
    func releasePending() {
        lock.lock()
        let callbacks = pending
        pending = []
        lock.unlock()
        callbacks.forEach { $0() }
    }
}

/// Records whether a lifecycle `Future` has resolved.
final class FutureCompletion {
    private let lock = NSLock()
    private var _isComplete = false
    private var cancellable: AnyCancellable?
    let expectation: XCTestExpectation

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isComplete
    }

    init(_ future: Future<Void, Never>, description: String) {
        expectation = XCTestExpectation(description: description)
        cancellable = future.sink { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self._isComplete = true
            self.lock.unlock()
            self.expectation.fulfill()
        }
    }
}

// MARK: - Tests

final class MixpanelOpenFeatureProviderTests: XCTestCase {

    // MARK: - Metadata & Hooks

    func testMetadata() {
        let provider = MixpanelOpenFeatureProvider(flags: MockMixpanelFlags())
        XCTAssertEqual(provider.metadata.name, "mixpanel-provider")
    }

    func testHooksEmpty() {
        let provider = MixpanelOpenFeatureProvider(flags: MockMixpanelFlags())
        XCTAssertTrue(provider.hooks.isEmpty)
    }

    // MARK: - Boolean Evaluation

    func testBooleanEvaluation() throws {
        let mock = MockMixpanelFlags()
        mock.variants["bool-flag"] = MixpanelFlagVariant(key: "on", value: true)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "bool-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(result.variant, "on")
        XCTAssertEqual(result.reason, "TARGETING_MATCH")
    }

    func testBooleanEvaluationTypeMismatch() throws {
        let mock = MockMixpanelFlags()
        mock.variants["str-flag"] = MixpanelFlagVariant(key: "v", value: "not-a-bool")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "str-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    // MARK: - String Evaluation

    func testStringEvaluation() throws {
        let mock = MockMixpanelFlags()
        mock.variants["str-flag"] = MixpanelFlagVariant(key: "variant-a", value: "hello")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "str-flag", defaultValue: "default", context: nil)
        XCTAssertEqual(result.value, "hello")
        XCTAssertEqual(result.variant, "variant-a")
        XCTAssertEqual(result.reason, "TARGETING_MATCH")
    }

    func testStringEvaluationTypeMismatch() throws {
        let mock = MockMixpanelFlags()
        mock.variants["bool-flag"] = MixpanelFlagVariant(key: "on", value: true)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "bool-flag", defaultValue: "default", context: nil)
        XCTAssertEqual(result.value, "default")
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    // MARK: - Integer Evaluation

    func testIntegerEvaluation() throws {
        let mock = MockMixpanelFlags()
        mock.variants["int-flag"] = MixpanelFlagVariant(key: "big", value: 42)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "int-flag", defaultValue: 0, context: nil)
        XCTAssertEqual(result.value, Int64(42))
        XCTAssertEqual(result.reason, "TARGETING_MATCH")
    }

    func testIntegerEvaluationFromWholeDouble() throws {
        let mock = MockMixpanelFlags()
        mock.variants["int-flag"] = MixpanelFlagVariant(key: "big", value: Double(42))
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "int-flag", defaultValue: 0, context: nil)
        XCTAssertEqual(result.value, Int64(42))
    }

    func testIntegerEvaluationTypeMismatch() throws {
        let mock = MockMixpanelFlags()
        mock.variants["str-flag"] = MixpanelFlagVariant(key: "v", value: "not-an-int")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "str-flag", defaultValue: 0, context: nil)
        XCTAssertEqual(result.value, Int64(0))
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    func testIntegerEvaluationFractionalDoubleTypeMismatch() throws {
        let mock = MockMixpanelFlags()
        mock.variants["float-flag"] = MixpanelFlagVariant(key: "v", value: 3.14)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "float-flag", defaultValue: 0, context: nil)
        XCTAssertEqual(result.value, Int64(0))
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    // MARK: - Double Evaluation

    func testDoubleEvaluation() throws {
        let mock = MockMixpanelFlags()
        mock.variants["float-flag"] = MixpanelFlagVariant(key: "half", value: 0.5)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "float-flag", defaultValue: 0.0, context: nil)
        XCTAssertEqual(result.value, 0.5)
        XCTAssertEqual(result.reason, "TARGETING_MATCH")
    }

    func testDoubleEvaluationFromInt() throws {
        let mock = MockMixpanelFlags()
        mock.variants["int-flag"] = MixpanelFlagVariant(key: "v", value: 42)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "int-flag", defaultValue: 0.0, context: nil)
        XCTAssertEqual(result.value, 42.0)
    }

    func testDoubleEvaluationTypeMismatch() throws {
        let mock = MockMixpanelFlags()
        mock.variants["str-flag"] = MixpanelFlagVariant(key: "v", value: "not-a-double")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "str-flag", defaultValue: 1.0, context: nil)
        XCTAssertEqual(result.value, 1.0)
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    // MARK: - Object Evaluation

    func testObjectEvaluation() throws {
        let mock = MockMixpanelFlags()
        mock.variants["obj-flag"] = MixpanelFlagVariant(
            key: "config", value: ["key": "value"] as [String: Any])
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getObjectEvaluation(key: "obj-flag", defaultValue: .null, context: nil)
        XCTAssertEqual(result.value, .structure(["key": .string("value")]))
        XCTAssertEqual(result.variant, "config")
        XCTAssertEqual(result.reason, "TARGETING_MATCH")
    }

    func testObjectEvaluationWithString() throws {
        let mock = MockMixpanelFlags()
        mock.variants["str-flag"] = MixpanelFlagVariant(key: "v", value: "hello")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getObjectEvaluation(key: "str-flag", defaultValue: .null, context: nil)
        XCTAssertEqual(result.value, .string("hello"))
    }

    // MARK: - Flag Not Found

    func testFlagNotFound() throws {
        let mock = MockMixpanelFlags()
        mock.ready = true
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "missing-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testFlagNotFoundAllTypes() throws {
        let mock = MockMixpanelFlags()
        mock.ready = true
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let strResult = try provider.getStringEvaluation(key: "missing", defaultValue: "fallback", context: nil)
        XCTAssertEqual(strResult.value, "fallback")
        XCTAssertEqual(strResult.errorCode, .flagNotFound)

        let intResult = try provider.getIntegerEvaluation(key: "missing", defaultValue: 99, context: nil)
        XCTAssertEqual(intResult.value, Int64(99))
        XCTAssertEqual(intResult.errorCode, .flagNotFound)

        let dblResult = try provider.getDoubleEvaluation(key: "missing", defaultValue: 3.14, context: nil)
        XCTAssertEqual(dblResult.value, 3.14)
        XCTAssertEqual(dblResult.errorCode, .flagNotFound)

        let objResult = try provider.getObjectEvaluation(
            key: "missing", defaultValue: .string("obj-default"), context: nil)
        XCTAssertEqual(objResult.value, .string("obj-default"))
        XCTAssertEqual(objResult.errorCode, .flagNotFound)
    }

    // MARK: - Context Forwarding

    func testInitializeForwardsContext() async throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: true)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        await provider.initialize(initialContext: ImmutableContext(targetingKey: "user-123")).value

        XCTAssertEqual(mock.lastSetContext?["targetingKey"] as? String, "user-123")

        let result = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, true)
    }

    func testInitializeWithNilContextSkipsSetContext() async throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: true)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        await provider.initialize(initialContext: nil).value

        XCTAssertNil(mock.lastSetContext)
    }

    func testOnContextSetForwardsContext() async throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: "hello")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let oldCtx = ImmutableContext(targetingKey: "user-old")
        let newCtx = ImmutableContext(targetingKey: "user-new")
        await provider.onContextSet(oldContext: oldCtx, newContext: newCtx).value

        XCTAssertEqual(mock.lastSetContext?["targetingKey"] as? String, "user-new")

        let result = try provider.getStringEvaluation(key: "flag", defaultValue: "default", context: nil)
        XCTAssertEqual(result.value, "hello")
    }

    // MARK: - Provider Status

    func testStatusNotReadyBeforeInitialize() {
        let provider = MixpanelOpenFeatureProvider(flags: MockMixpanelFlags())
        XCTAssertEqual(provider.status, .notReady)
    }

    func testInitializeWithContextReadyWhenFlagsLoad() async {
        let provider = MixpanelOpenFeatureProvider(flags: MockMixpanelFlags())

        await provider.initialize(initialContext: ImmutableContext(targetingKey: "user-123")).value

        XCTAssertEqual(provider.status, .ready)
    }

    func testInitializeWithContextErrorWhenFlagsFailToLoad() async {
        let mock = MockMixpanelFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        await provider.initialize(initialContext: ImmutableContext(targetingKey: "user-123")).value

        XCTAssertEqual(provider.status, .error)
    }

    func testInitializeWithNilContextLoadsFlags() async {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        await provider.initialize(initialContext: nil).value

        XCTAssertEqual(mock.loadFlagsCallCount, 1)
        XCTAssertEqual(provider.status, .ready)
    }

    func testInitializeWithNilContextErrorWhenFlagsFailToLoad() async {
        let mock = MockMixpanelFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        await provider.initialize(initialContext: nil).value

        XCTAssertEqual(provider.status, .error)
    }

    func testOnContextSetEmitsReconcilingThenContextChanged() async {
        let provider = MixpanelOpenFeatureProvider(flags: MockMixpanelFlags())
        await provider.initialize(initialContext: nil).value

        let events = await collectEvents(from: provider, count: 3) {
            _ = provider.onContextSet(oldContext: nil, newContext: ImmutableContext(targetingKey: "user-new"))
        }

        // First event is the tracker replaying the current (.ready) status to the new subscriber.
        XCTAssertEqual(events, [.ready(nil), .reconciling(nil), .contextChanged(nil)])
        XCTAssertEqual(provider.status, .ready)
    }

    func testOnContextSetEmitsErrorWhenFlagsFailToLoad() async {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        await provider.initialize(initialContext: nil).value
        mock.ready = false

        let events = await collectEvents(from: provider, count: 3) {
            _ = provider.onContextSet(oldContext: nil, newContext: ImmutableContext(targetingKey: "user-new"))
        }

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.prefix(2), [.ready(nil), .reconciling(nil)])
        if case .error = events.last {
        } else {
            XCTFail("Expected .error, got \(String(describing: events.last))")
        }
        XCTAssertEqual(provider.status, .error)
    }

    // MARK: - Pending Loads

    func testInitializeStaysNotReadyAndUnfinishedUntilFlagsLoad() async {
        let mock = HeldCallbackMockFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let completion = FutureCompletion(
            provider.initialize(initialContext: ImmutableContext(targetingKey: "user-123")),
            description: "initialize resolves")

        XCTAssertEqual(mock.pendingCount, 1)
        XCTAssertEqual(provider.status, .notReady)
        XCTAssertFalse(completion.isComplete)

        mock.releasePending()
        await fulfillment(of: [completion.expectation], timeout: 5.0)

        XCTAssertEqual(provider.status, .ready)
        XCTAssertTrue(completion.isComplete)
    }

    func testInitializeWithNilContextStaysNotReadyAndUnfinishedUntilFlagsLoad() async {
        let mock = HeldCallbackMockFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let completion = FutureCompletion(
            provider.initialize(initialContext: nil), description: "initialize resolves")

        XCTAssertEqual(mock.pendingCount, 1)
        XCTAssertEqual(provider.status, .notReady)
        XCTAssertFalse(completion.isComplete)

        mock.releasePending()
        await fulfillment(of: [completion.expectation], timeout: 5.0)

        XCTAssertEqual(provider.status, .ready)
        XCTAssertTrue(completion.isComplete)
    }

    func testInitializeErrorsOnlyAfterFlagsFailToLoad() async {
        let mock = HeldCallbackMockFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let completion = FutureCompletion(
            provider.initialize(initialContext: ImmutableContext(targetingKey: "user-123")),
            description: "initialize resolves")

        XCTAssertEqual(provider.status, .notReady)
        XCTAssertFalse(completion.isComplete)

        mock.releasePending()
        await fulfillment(of: [completion.expectation], timeout: 5.0)

        XCTAssertEqual(provider.status, .error)
    }

    func testOnContextSetStaysReconcilingAndUnfinishedUntilFlagsLoad() async {
        let mock = HeldCallbackMockFlags()
        mock.holdCallbacks = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        await provider.initialize(initialContext: nil).value
        XCTAssertEqual(provider.status, .ready)

        mock.holdCallbacks = true
        let completion = FutureCompletion(
            provider.onContextSet(oldContext: nil, newContext: ImmutableContext(targetingKey: "user-new")),
            description: "onContextSet resolves")

        // The fetch is in flight: still reconciling, and the Future hasn't resolved.
        XCTAssertEqual(mock.pendingCount, 1)
        XCTAssertEqual(provider.status, .reconciling)
        XCTAssertFalse(completion.isComplete)

        mock.releasePending()
        await fulfillment(of: [completion.expectation], timeout: 5.0)

        XCTAssertEqual(provider.status, .ready)
        XCTAssertTrue(completion.isComplete)
    }

    func testOnContextSetErrorsOnlyAfterFlagsFailToLoad() async {
        let mock = HeldCallbackMockFlags()
        mock.holdCallbacks = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        await provider.initialize(initialContext: nil).value

        mock.holdCallbacks = true
        mock.ready = false
        let completion = FutureCompletion(
            provider.onContextSet(oldContext: nil, newContext: ImmutableContext(targetingKey: "user-new")),
            description: "onContextSet resolves")

        XCTAssertEqual(provider.status, .reconciling)
        XCTAssertFalse(completion.isComplete)

        mock.releasePending()
        await fulfillment(of: [completion.expectation], timeout: 5.0)

        XCTAssertEqual(provider.status, .error)
        XCTAssertTrue(completion.isComplete)
    }

    // MARK: - Status Recovery On Evaluation

    func testEvaluationClearsErrorOnceFlagsLoad() async throws {
        let mock = MockMixpanelFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        await provider.initialize(initialContext: nil).value
        XCTAssertEqual(provider.status, .error)

        // A later background fetch succeeds.
        mock.ready = true
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: true)

        let events = await collectEvents(from: provider, count: 2) {
            let result = try? provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)
            XCTAssertEqual(result?.value, true)
        }

        // First event is the tracker replaying the current (.error) status to the new subscriber.
        XCTAssertEqual(events.last, .ready(nil))
        XCTAssertEqual(provider.status, .ready)
    }

    /// `identify()` with a new distinct ID resets Mixpanel's flags, completing an in-flight
    /// load with no flags. The new identity's fetch then loads them.
    func testEvaluationClearsErrorAfterIdentifyResetDuringInitialize() async throws {
        let mock = HeldCallbackMockFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        let completion = FutureCompletion(
            provider.initialize(initialContext: nil), description: "initialize resolves")

        mock.ready = false
        mock.releasePending()
        await fulfillment(of: [completion.expectation], timeout: 5.0)
        XCTAssertEqual(provider.status, .error)

        mock.ready = true
        _ = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)

        XCTAssertEqual(provider.status, .ready)
    }

    func testEvaluationKeepsErrorWhileFlagsAreNotReady() async throws {
        let mock = MockMixpanelFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        await provider.initialize(initialContext: nil).value

        _ = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)

        XCTAssertEqual(provider.status, .error)
    }

    func testEvaluationDoesNotChangeStatusBeforeInitialize() throws {
        let provider = MixpanelOpenFeatureProvider(flags: MockMixpanelFlags())

        _ = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)

        XCTAssertEqual(provider.status, .notReady)
    }

    func testEvaluationDoesNotChangeStatusWhileReconciling() async throws {
        let mock = HeldCallbackMockFlags()
        mock.holdCallbacks = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        await provider.initialize(initialContext: nil).value

        mock.holdCallbacks = true
        _ = provider.onContextSet(oldContext: nil, newContext: ImmutableContext(targetingKey: "user-new"))
        _ = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)

        XCTAssertEqual(provider.status, .reconciling)
        mock.releasePending()
    }

    /// Subscribes to the provider's events, runs `action`, and returns the first `count` events.
    private func collectEvents(
        from provider: MixpanelOpenFeatureProvider, count: Int, action: () -> Void
    ) async -> [ProviderEvent] {
        let received = expectation(description: "received \(count) events")
        let lock = NSLock()
        var events: [ProviderEvent] = []
        let cancellable = provider.observe().sink { event in
            lock.lock()
            events.append(event)
            let done = events.count == count
            lock.unlock()
            if done { received.fulfill() }
        }
        action()
        await fulfillment(of: [received], timeout: 5.0)
        cancellable.cancel()
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func testInitializeForwardsAttributes() async throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let context = ImmutableContext(
            targetingKey: "user-123",
            structure: ImmutableStructure(attributes: [
                "plan": .string("premium"),
                "age": .integer(30),
                "score": .double(9.5),
                "active": .boolean(true),
            ])
        )
        await provider.initialize(initialContext: context).value

        XCTAssertEqual(mock.lastSetContext?["targetingKey"] as? String, "user-123")
        XCTAssertEqual(mock.lastSetContext?["plan"] as? String, "premium")
        XCTAssertEqual(mock.lastSetContext?["age"] as? Int64, 30)
        XCTAssertEqual(mock.lastSetContext?["score"] as? Double, 9.5)
        XCTAssertEqual(mock.lastSetContext?["active"] as? Bool, true)
    }

    func testPerEvaluationContextIsIgnored() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: 42)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let ctx = ImmutableContext(targetingKey: "user-123")

        // Passing a per-evaluation context should not change the result
        let resultWithContext = try provider.getIntegerEvaluation(key: "flag", defaultValue: 0, context: ctx)
        let resultWithoutContext = try provider.getIntegerEvaluation(key: "flag", defaultValue: 0, context: nil)
        XCTAssertEqual(resultWithContext.value, resultWithoutContext.value)
        XCTAssertEqual(resultWithContext.value, Int64(42))
    }

    // MARK: - Variant Key Passthrough

    func testVariantKeyIncludedInBooleanResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "treatment-v2", value: true)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.variant, "treatment-v2")
    }

    func testVariantKeyIncludedInStringResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "variant-abc", value: "val")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "flag", defaultValue: "", context: nil)
        XCTAssertEqual(result.variant, "variant-abc")
    }

    func testVariantKeyIncludedInIntegerResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "big-bucket", value: 99)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "flag", defaultValue: 0, context: nil)
        XCTAssertEqual(result.variant, "big-bucket")
    }

    func testVariantKeyIncludedInDoubleResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "half-group", value: 0.5)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "flag", defaultValue: 0.0, context: nil)
        XCTAssertEqual(result.variant, "half-group")
    }

    func testVariantKeyIncludedInObjectResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "obj-variant", value: ["a": 1] as [String: Any])
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getObjectEvaluation(key: "flag", defaultValue: .null, context: nil)
        XCTAssertEqual(result.variant, "obj-variant")
    }

    // MARK: - Nil / Empty Variant Key

    func testEmptyVariantKeyInBooleanResolution() throws {
        let mock = MockMixpanelFlags()
        // MixpanelFlagVariant with no explicit key defaults key to ""
        mock.variants["flag"] = MixpanelFlagVariant(value: true)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(result.variant, "")
    }

    func testEmptyVariantKeyInStringResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(value: "hello")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "flag", defaultValue: "", context: nil)
        XCTAssertEqual(result.value, "hello")
        XCTAssertEqual(result.variant, "")
    }

    func testEmptyVariantKeyInIntegerResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(value: 10)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "flag", defaultValue: 0, context: nil)
        XCTAssertEqual(result.value, Int64(10))
        XCTAssertEqual(result.variant, "")
    }

    func testEmptyVariantKeyInDoubleResolution() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(value: 3.14)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "flag", defaultValue: 0.0, context: nil)
        XCTAssertEqual(result.value, 3.14)
        XCTAssertEqual(result.variant, "")
    }

    // MARK: - SDK Exception Handling

    func testSDKReturnsUnexpectedResultBooleanReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "some-flag", defaultValue: true, context: nil)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testSDKReturnsUnexpectedResultStringReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "some-flag", defaultValue: "default", context: nil)
        XCTAssertEqual(result.value, "default")
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testSDKReturnsUnexpectedResultIntegerReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "some-flag", defaultValue: 7, context: nil)
        XCTAssertEqual(result.value, Int64(7))
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testSDKReturnsUnexpectedResultDoubleReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "some-flag", defaultValue: 2.71, context: nil)
        XCTAssertEqual(result.value, 2.71)
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testSDKReturnsUnexpectedResultObjectReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getObjectEvaluation(
            key: "some-flag", defaultValue: .string("sentinel-default"), context: nil)
        XCTAssertEqual(result.value, .string("sentinel-default"))
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    // MARK: - Provider Not Ready

    func testProviderNotReady() throws {
        let mock = MockMixpanelFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "any-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .providerNotReady)
    }

    func testProviderNotReadyAllTypes() throws {
        let mock = MockMixpanelFlags()
        mock.ready = false
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let strResult = try provider.getStringEvaluation(key: "f", defaultValue: "d", context: nil)
        XCTAssertEqual(strResult.value, "d")
        XCTAssertEqual(strResult.errorCode, .providerNotReady)

        let intResult = try provider.getIntegerEvaluation(key: "f", defaultValue: 0, context: nil)
        XCTAssertEqual(intResult.value, Int64(0))
        XCTAssertEqual(intResult.errorCode, .providerNotReady)

        let dblResult = try provider.getDoubleEvaluation(key: "f", defaultValue: 0.0, context: nil)
        XCTAssertEqual(dblResult.value, 0.0)
        XCTAssertEqual(dblResult.errorCode, .providerNotReady)

        let objResult = try provider.getObjectEvaluation(key: "f", defaultValue: .null, context: nil)
        XCTAssertEqual(objResult.value, .null)
        XCTAssertEqual(objResult.errorCode, .providerNotReady)
    }

    // MARK: - Fallback Reason Dispatch (SDK-79 / SDK-132)

    // The base SDK returns `MixpanelFlagVariant` stamped with
    // `Source.fallback(reason:)` when it can't serve a real variant. The three
    // reasons carry distinct meaning:
    //   .flagNotFound  — key not in the cache or /flags response
    //   .notReady      — flags haven't loaded yet
    //   .backendError  — /flags fetch failed and nothing cached
    //
    // Before SDK-132 the wrapper collapsed all three to `.flagNotFound` via a
    // sentinel-key trick. These tests pin the post-fix mapping.

    func testFallbackReasonFlagNotFoundMapsToFlagNotFound() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)
        // Any missing key gets the default `.fallback(reason: .flagNotFound)`
        // stamp from the mock — see MockMixpanelFlags.getVariantSync.

        let result = try provider.getBooleanEvaluation(key: "missing", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.errorCode, .flagNotFound)
        XCTAssertEqual(result.reason, "DEFAULT")
    }

    func testFallbackReasonNotReadyMapsToProviderNotReady() throws {
        let mock = MockMixpanelFlags()
        // Keep areFlagsReady() == true so the early-return doesn't fire, then
        // simulate a base SDK that stamps `.notReady` on the sync path anyway
        // (a race the switch below is meant to catch).
        mock.variantSources["stale-flag"] = .fallback(reason: .notReady)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "stale-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.errorCode, .providerNotReady)
        XCTAssertEqual(result.reason, "ERROR")
    }

    func testFallbackReasonBackendErrorMapsToGeneral() throws {
        let mock = MockMixpanelFlags()
        mock.variantSources["broken-flag"] = .fallback(reason: .backendError)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "broken-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.errorCode, .general)
        XCTAssertEqual(result.reason, "ERROR")
    }

    func testFallbackReasonBackendErrorAllTypes() throws {
        let mock = MockMixpanelFlags()
        mock.variantSources["broken"] = .fallback(reason: .backendError)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let str = try provider.getStringEvaluation(key: "broken", defaultValue: "d", context: nil)
        XCTAssertEqual(str.errorCode, .general)
        XCTAssertEqual(str.reason, "ERROR")

        let int = try provider.getIntegerEvaluation(key: "broken", defaultValue: 0, context: nil)
        XCTAssertEqual(int.errorCode, .general)
        XCTAssertEqual(int.reason, "ERROR")

        let dbl = try provider.getDoubleEvaluation(key: "broken", defaultValue: 0.0, context: nil)
        XCTAssertEqual(dbl.errorCode, .general)
        XCTAssertEqual(dbl.reason, "ERROR")

        let obj = try provider.getObjectEvaluation(key: "broken", defaultValue: .null, context: nil)
        XCTAssertEqual(obj.errorCode, .general)
        XCTAssertEqual(obj.reason, "ERROR")
    }

    func testNetworkSourcedVariantResolvesSuccessfully() throws {
        // Guards against a regression where the switch on `.fallback` would
        // accidentally match successful `.network` / `.persistence` variants.
        let mock = MockMixpanelFlags()
        mock.variants["real-flag"] = MixpanelFlagVariant(key: "treatment", value: true)
        // Mock stamps .network by default when a variant is present.
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "real-flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(result.variant, "treatment")
        XCTAssertEqual(result.reason, "TARGETING_MATCH")
        XCTAssertNil(result.errorCode)
    }

    // MARK: - Default Value Fallback

    func testBooleanFlagNotFoundReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "missing", defaultValue: true, context: nil)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testStringFlagNotFoundReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "missing", defaultValue: "fallback", context: nil)
        XCTAssertEqual(result.value, "fallback")
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testIntegerFlagNotFoundReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "missing", defaultValue: 42, context: nil)
        XCTAssertEqual(result.value, Int64(42))
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testDoubleFlagNotFoundReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "missing", defaultValue: 1.5, context: nil)
        XCTAssertEqual(result.value, 1.5)
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testObjectFlagNotFoundReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getObjectEvaluation(key: "missing", defaultValue: .boolean(true), context: nil)
        XCTAssertEqual(result.value, .boolean(true))
        XCTAssertEqual(result.reason, "DEFAULT")
        XCTAssertEqual(result.errorCode, .flagNotFound)
    }

    func testBooleanTypeMismatchReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: 42)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getBooleanEvaluation(key: "flag", defaultValue: false, context: nil)
        XCTAssertEqual(result.value, false)
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    func testStringTypeMismatchReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: 99)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getStringEvaluation(key: "flag", defaultValue: "my-default", context: nil)
        XCTAssertEqual(result.value, "my-default")
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    func testIntegerTypeMismatchReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: "not-an-int")
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getIntegerEvaluation(key: "flag", defaultValue: 100, context: nil)
        XCTAssertEqual(result.value, Int64(100))
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }

    func testDoubleTypeMismatchReturnsDefault() throws {
        let mock = MockMixpanelFlags()
        mock.variants["flag"] = MixpanelFlagVariant(key: "v", value: false)
        let provider = MixpanelOpenFeatureProvider(flags: mock)

        let result = try provider.getDoubleEvaluation(key: "flag", defaultValue: 9.99, context: nil)
        XCTAssertEqual(result.value, 9.99)
        XCTAssertEqual(result.reason, "ERROR")
        XCTAssertEqual(result.errorCode, .typeMismatch)
    }
}
