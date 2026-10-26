import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

/// Review regressions for #309. Drive finishTextOutput through its real
/// pre-injection decision, stopping before clipboard, AX, or history writes.
/// Snippet rules are explicit fixtures, never the user's stored vocabulary.
final class IntelliSenseReviewRegressionTests: XCTestCase {
    func testSensitiveProcessingDestinationDisablesTrackingAndBothLearners() async throws {
        let (output, inputs) = await learningCase(availability: .sensitive)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.contextAvailability, .sensitive)
        XCTAssertFalse(result.shouldTrackLearning)
        XCTAssertFalse(result.learningPlan.correctionEnabled)
        XCTAssertFalse(result.learningPlan.expressionLearningEnabled)
        XCTAssertEqual(result.text, "一段普通测试文本")
        XCTAssertEqual(inputs, ["一段普通测试文本"])
    }

    func testBlacklistedProcessingDestinationDisablesTrackingAndBothLearners() async throws {
        let (output, _) = await learningCase(availability: .blacklisted)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.contextAvailability, .blacklisted)
        XCTAssertFalse(result.shouldTrackLearning)
        XCTAssertFalse(result.learningPlan.correctionEnabled)
        XCTAssertFalse(result.learningPlan.expressionLearningEnabled)
    }

    func testOrdinaryProcessingDestinationStillEnablesBothLearners() async throws {
        let (output, _) = await learningCase(availability: .appAndControl)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.contextAvailability, .appAndControl)
        XCTAssertTrue(result.shouldTrackLearning)
        XCTAssertTrue(result.learningPlan.correctionEnabled)
        XCTAssertTrue(result.learningPlan.expressionLearningEnabled)
    }

    func testLateReceiverSwitchDoesNotReuseAnotherAppsSensitiveSnapshotOrRerunLLM() async throws {
        let receiver = reviewTarget("com.example.receiver", pid: 3303)
        let (output, inputs) = await learningCase(availability: .sensitive, receiver: receiver)
        let result = try XCTUnwrap(output)
        XCTAssertNil(result.contextAvailability)
        // Preserve the existing unknown-context policy; this does not classify C as safe.
        XCTAssertTrue(result.shouldTrackLearning)
        XCTAssertTrue(result.trace?.contains("com.example.processing") == true)
        XCTAssertFalse(result.trace?.contains("com.example.receiver") == true)
        XCTAssertEqual(inputs.count, 1)
    }

    func testLateSwitchIntoBlacklistedReceiverStillBlocksTracking() async throws {
        let receiver = reviewTarget("com.example.receiver", pid: 3303)
        let (output, inputs) = await learningCase(
            availability: .appAndControl, receiver: receiver, blacklistReceiver: true
        )
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.contextAvailability, .blacklisted)
        XCTAssertFalse(result.shouldTrackLearning)
        XCTAssertFalse(result.learningPlan.correctionEnabled)
        XCTAssertFalse(result.learningPlan.expressionLearningEnabled)
        XCTAssertEqual(inputs.count, 1)
    }

    func testDestinationSnippetOutputAndProvenanceUseTheSameScopedPass() async throws {
        let destination = reviewTarget("com.example.processing", pid: 3402)
        let client = ReviewEchoLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: "Doc",
            startingSnapshot: reviewSnapshot(reviewTarget("com.example.start", pid: 3401)),
            settings: reviewSettings(),
            applySnippets: { text, bundleID in
                SnippetStorage.apply(
                    to: text, globalRules: [("Doc", "Docker")],
                    appRules: [("Doc", "文档")], bundleId: bundleID
                )
            },
            currentTarget: { destination },
            capture: { target, _ in reviewSnapshot(target) }
        )
        let result = try XCTUnwrap(output)
        let application = try XCTUnwrap(result.snippets)
        let inputs = await client.inputs()
        XCTAssertEqual(inputs, ["文档"])
        XCTAssertEqual(result.text, "文档")
        XCTAssertEqual(application.text, "文档")
        XCTAssertEqual(application.appliedRules, [
            AppliedSnippetRule(trigger: "Doc", value: "文档", bundleId: destination.bundleIdentifier)
        ])
    }

    func testSwitchDuringCaptureRecomputesFromRawTextAndReplacesProvenance() async throws {
        let (output, inputs) = await snippetSwitchCase(finalHasRule: true)
        let result = try XCTUnwrap(output)
        let application = try XCTUnwrap(result.snippets)
        XCTAssertEqual(inputs, ["文档"])
        XCTAssertEqual(result.text, "文档")
        XCTAssertEqual(application.text, "文档")
        XCTAssertEqual(application.appliedRules, [
            AppliedSnippetRule(trigger: "Doc", value: "文档", bundleId: "com.example.final")
        ])
        XCTAssertTrue(result.trace?.contains("com.example.final") == true)
        XCTAssertFalse(result.trace?.contains("com.example.processing") == true)
    }

    func testSwitchToDestinationWithoutMatchingRulesClearsEarlierProvenance() async throws {
        let (output, inputs) = await snippetSwitchCase(finalHasRule: false)
        let result = try XCTUnwrap(output)
        let application = try XCTUnwrap(result.snippets)
        XCTAssertEqual(inputs, ["Doc"])
        XCTAssertEqual(result.text, "Doc")
        XCTAssertEqual(application.text, "Doc")
        XCTAssertTrue(application.appliedRules.isEmpty)
    }

    func testManualInputRecordsKnownEmptyProvenanceWithoutApplyingRules() async throws {
        let destination = reviewTarget("com.example.processing", pid: 3502)
        let client = ReviewEchoLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: "Doc",
            startingSnapshot: reviewSnapshot(reviewTarget("com.example.start", pid: 3501)),
            settings: reviewSettings(),
            manualInput: true,
            applySnippets: { text, _ in
                XCTFail("Manual input must not evaluate snippet rules")
                return SnippetApplication(text: text, appliedRules: [])
            },
            currentTarget: { destination },
            capture: { target, _ in
                XCTFail("Manual input must retain its original processing context")
                return reviewSnapshot(target)
            }
        )
        let result = try XCTUnwrap(output)
        let application = try XCTUnwrap(result.snippets)
        XCTAssertEqual(application.text, "Doc")
        XCTAssertTrue(application.appliedRules.isEmpty)
        XCTAssertFalse(result.shouldTrackLearning)
    }

    func testShortTextExemptionRetainsDestinationSnippetProvenanceWithoutCapture() async throws {
        let destination = reviewTarget("com.example.processing", pid: 3602)
        let client = ReviewEchoLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: "Doc",
            startingSnapshot: reviewSnapshot(reviewTarget("com.example.start", pid: 3601)),
            settings: reviewSettings(),
            shortTextExemption: 100,
            applySnippets: { text, bundleID in
                SnippetStorage.apply(to: text, globalRules: [], appRules: [("Doc", "文档")], bundleId: bundleID)
            },
            currentTarget: { destination },
            capture: { target, _ in
                XCTFail("Short-text exemption must not capture destination context")
                return reviewSnapshot(target)
            }
        )
        let result = try XCTUnwrap(output)
        let application = try XCTUnwrap(result.snippets)
        let inputs = await client.inputs()
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(result.text, "文档")
        XCTAssertEqual(application.appliedRules, [
            AppliedSnippetRule(trigger: "Doc", value: "文档", bundleId: destination.bundleIdentifier)
        ])
    }

    private func learningCase(
        availability: ContextAvailability,
        receiver: TargetApplicationContext? = nil,
        blacklistReceiver: Bool = false
    ) async -> (RecognitionSession.IntelliSenseOutputForTesting?, [String]) {
        let processing = reviewTarget("com.example.processing", pid: 3302)
        let current = ReviewTargetBox(processing)
        var settings = reviewSettings(learning: true)
        if blacklistReceiver, let bundleID = receiver?.bundleIdentifier {
            settings.blacklistedApps = [.init(bundleIdentifier: bundleID, displayName: bundleID)]
        }
        let client = ReviewEchoLLMClient {
            if let receiver { current.set(receiver) }
        }
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: "一段普通测试文本",
            startingSnapshot: reviewSnapshot(reviewTarget("com.example.start", pid: 3301)),
            settings: settings,
            currentTarget: { current.value() },
            capture: { target, _ in reviewSnapshot(target, availability: availability) }
        )
        return (output, await client.inputs())
    }

    private func snippetSwitchCase(
        finalHasRule: Bool
    ) async -> (RecognitionSession.IntelliSenseOutputForTesting?, [String]) {
        let processing = reviewTarget("com.example.processing", pid: 3702)
        let destination = reviewTarget("com.example.final", pid: 3703)
        let current = ReviewTargetBox(processing)
        let client = ReviewEchoLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: "Doc",
            startingSnapshot: reviewSnapshot(reviewTarget("com.example.start", pid: 3701)),
            settings: reviewSettings(),
            applySnippets: { text, bundleID in
                let rules: [(trigger: String, value: String)]
                if bundleID == processing.bundleIdentifier {
                    rules = [("Doc", "Docker")]
                } else {
                    // Applying C to B's already-expanded output would produce the wrong text.
                    rules = finalHasRule ? [("Doc", "文档"), ("Docker", "错误的二次替换")] : []
                }
                return SnippetStorage.apply(to: text, globalRules: [], appRules: rules, bundleId: bundleID)
            },
            currentTarget: { current.value() },
            capture: { target, _ in
                current.set(destination)
                return reviewSnapshot(target)
            }
        )
        return (output, await client.inputs())
    }
}

private func reviewTarget(_ bundleID: String, pid: pid_t) -> TargetApplicationContext {
    TargetApplicationContext(processIdentifier: pid, bundleIdentifier: bundleID, displayName: bundleID)
}

private func reviewSnapshot(
    _ target: TargetApplicationContext,
    availability: ContextAvailability = .appAndControl
) -> IntelliSenseContextSnapshot {
    IntelliSenseContextSnapshot(
        bundleIdentifier: target.bundleIdentifier,
        appName: target.displayName,
        appCategory: AppContextClassifier.classify(bundleIdentifier: target.bundleIdentifier, appName: target.displayName),
        controlCategory: .multiLine,
        contextBeforeCursor: "",
        contextAfterCursor: "",
        availability: availability,
        wasTruncated: false
    )
}

private func reviewSettings(learning: Bool = false) -> IntelliSenseSettings {
    IntelliSenseSettings(
        applicationAwarenessEnabled: true,
        contextAwarenessEnabled: true,
        correctionDetectionEnabled: learning,
        expressionLearningEnabled: learning
    )
}

private final class ReviewTargetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var target: TargetApplicationContext

    init(_ target: TargetApplicationContext) { self.target = target }

    func value() -> TargetApplicationContext {
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    func set(_ target: TargetApplicationContext) {
        lock.lock()
        defer { lock.unlock() }
        self.target = target
    }
}

private actor ReviewEchoLLMClient: LLMClient {
    private var recordedInputs: [String] = []
    private let afterProcess: (@Sendable () -> Void)?

    init(afterProcess: (@Sendable () -> Void)? = nil) { self.afterProcess = afterProcess }

    func process(text: String, prompt: String, config: LLMConfig, inputBoundary: LLMInputBoundary) async throws -> String {
        recordedInputs.append(text)
        afterProcess?()
        return text
    }

    func inputs() -> [String] { recordedInputs }
    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
