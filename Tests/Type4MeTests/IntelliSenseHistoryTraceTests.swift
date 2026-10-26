import XCTest
@testable import Type4MeIntelliSenseCore

final class IntelliSenseHistoryTraceTests: XCTestCase {
    func testSearchTraceRecordsSceneAndEffectsWithoutPersistingPrivateInputs() throws {
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        settings.contextAwarenessEnabled = true
        settings.expressionLearningEnabled = true
        let context = snapshot(
            appName: "Dia",
            category: .browser,
            control: .search,
            availability: .appAndControl,
            before: "PRIVATE_NEARBY_TEXT"
        )
        let result = IntelliSenseOutputValidator.process(
            input: "帮我查一下新加坡明天的天气怎么样",
            candidate: "新加坡明天天气",
            context: context
        )
        let trace = IntelliSenseHistoryTraceBuilder.build(
            input: "帮我查一下新加坡明天的天气怎么样",
            finalText: result.finalText,
            promptInput: .init(
                context: context,
                settings: settings,
                expressionProfile: EffectiveExpressionProfile(
                    directives: ["PRIVATE_EXPRESSION_DIRECTIVE"],
                    sourceScope: "app"
                )
            ),
            processingResult: result,
            processingFailed: false
        )

        XCTAssertEqual(trace.appName, "Dia")
        XCTAssertEqual(trace.scene, .search)
        XCTAssertEqual(trace.enabledLayers, [.application, .context, .expression])
        XCTAssertEqual(trace.appliedLayers, [.application, .expression])
        XCTAssertTrue(trace.effects.contains(.searchQueryCompressed))

        let json = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_NEARBY_TEXT"))
        XCTAssertFalse(json.contains("PRIVATE_EXPRESSION_DIRECTIVE"))
        XCTAssertFalse(json.contains("contextBeforeCursor"))
        XCTAssertFalse(json.contains("directives"))
    }

    func testFullContextAndStableExpressionAreRecordedAsAppliedLayers() {
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        settings.contextAwarenessEnabled = true
        settings.expressionLearningEnabled = true
        let context = snapshot(
            appName: "Notes",
            category: .document,
            control: .multiLine,
            availability: .full,
            before: "Qwen3-ASR 发布计划"
        )
        let result = IntelliSenseOutputValidator.process(
            input: "Queen 三 ASR 明天发布。",
            candidate: "Qwen3-ASR 明天发布。",
            context: context
        )
        let trace = IntelliSenseHistoryTraceBuilder.build(
            input: "Queen 三 ASR 明天发布。",
            finalText: result.finalText,
            promptInput: .init(
                context: context,
                settings: settings,
                expressionProfile: EffectiveExpressionProfile(directives: ["偏好简短表达"])
            ),
            processingResult: result,
            processingFailed: false
        )

        XCTAssertEqual(trace.appliedLayers, [.application, .context, .expression])
        XCTAssertTrue(trace.effects.contains(.contextTermAdopted))
    }

    func testExplicitCorrectionAndGuardFallbackUseDeterministicEffects() {
        let context = snapshot(
            appName: "Notes",
            category: .document,
            control: .multiLine,
            availability: .appAndControl
        )
        let correctionInput = "我们下午3点开会，不对，改成4点。"
        let correctionResult = IntelliSenseOutputValidator.process(
            input: correctionInput,
            candidate: "我们下午4点开会。",
            context: context
        )
        let correctionTrace = IntelliSenseHistoryTraceBuilder.build(
            input: correctionInput,
            finalText: correctionResult.finalText,
            promptInput: .init(context: context, settings: .init(), expressionProfile: nil),
            processingResult: correctionResult,
            processingFailed: false
        )
        XCTAssertTrue(correctionTrace.correctionDetected)
        XCTAssertTrue(correctionTrace.effects.contains(.explicitCorrectionApplied))

        let rejected = IntelliSenseOutputValidator.process(
            input: "这个版本明天发布。",
            candidate: "This version ships tomorrow.",
            context: context
        )
        let rejectedTrace = IntelliSenseHistoryTraceBuilder.build(
            input: "这个版本明天发布。",
            finalText: rejected.finalText,
            promptInput: .init(context: context, settings: .init(), expressionProfile: nil),
            processingResult: rejected,
            processingFailed: false
        )
        XCTAssertEqual(rejectedTrace.guardOutcome, .reject)
        XCTAssertEqual(rejectedTrace.guardRejection, .languageChanged)
        XCTAssertEqual(rejectedTrace.effects, [.protectedResultFallback])
    }

    func testProcessingFailureDoesNotClaimEnhancedAwarenessWasApplied() {
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        settings.contextAwarenessEnabled = true
        settings.expressionLearningEnabled = true
        let trace = IntelliSenseHistoryTraceBuilder.build(
            input: "原始文本",
            finalText: "原始文本",
            promptInput: .init(
                context: snapshot(
                    appName: "Mail",
                    category: .email,
                    control: .multiLine,
                    availability: .full,
                    before: "附近文字"
                ),
                settings: settings,
                expressionProfile: EffectiveExpressionProfile(directives: ["偏好完整表达"])
            ),
            processingResult: nil,
            processingFailed: true
        )

        XCTAssertEqual(trace.enabledLayers, [.application, .context, .expression])
        XCTAssertTrue(trace.appliedLayers.isEmpty)
        XCTAssertNil(trace.scene)
        XCTAssertEqual(trace.effects, [.processingFallback])
        XCTAssertEqual(trace.guardOutcome, .unavailable)
    }

    func testBrowserListRestructureGetsGenericHistoryEffect() {
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        let context = snapshot(
            appName: "Dia",
            category: .browser,
            control: .multiLine,
            availability: .appAndControl
        )
        let input = "报价分为三块。第一块是 License，第二块是 Studios，第三块是 FDE。"
        let output = "报价分为三块：\n1. License；\n2. Studios；\n3. FDE。"
        let result = IntelliSenseOutputValidator.process(
            input: input,
            candidate: output,
            context: context
        )
        let trace = IntelliSenseHistoryTraceBuilder.build(
            input: input,
            finalText: output,
            promptInput: .init(context: context, settings: settings, expressionProfile: nil),
            processingResult: result,
            processingFailed: false
        )

        XCTAssertEqual(trace.scene, .browser)
        XCTAssertTrue(trace.effects.contains(.listStructured))
        XCTAssertFalse(trace.effects.contains(.generalPolish))
    }

    private func snapshot(
        appName: String,
        category: ApplicationCategory,
        control: InputControlCategory,
        availability: ContextAvailability,
        before: String = ""
    ) -> IntelliSenseContextSnapshot {
        IntelliSenseContextSnapshot(
            bundleIdentifier: "com.example.\(appName.lowercased())",
            appName: appName,
            appCategory: category,
            controlCategory: control,
            contextBeforeCursor: before,
            contextAfterCursor: "",
            availability: availability,
            wasTruncated: false
        )
    }
}
