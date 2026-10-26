import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class IntelliSenseDestinationTests: XCTestCase {
    func testProcessingRefreshesChatGPTSnapshotToWeChatBeforePromptAndTrace() async {
        let weChat = target(pid: 2101, bundleID: "com.tencent.xinWeChat", name: "WeChat")
        let currentTarget = TargetBox(weChat)
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "请把这段话发给对方",
            startingSnapshot: developmentSnapshot(),
            settings: awarenessSettings(),
            currentTarget: { currentTarget.value() },
            capture: { target, settings in
                await captures.record(target)
                return capturedSnapshot(for: target, settings: settings)
            }
        )

        let prompts = await client.prompts()
        let capturedTargets = await captures.targets()
        XCTAssertEqual(capturedTargets, [weChat])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("当前是聊天场景"))
        XCTAssertFalse(prompts[0].contains("当前是开发工具"))
        XCTAssertFalse(prompts[0].contains("SYNTHETIC_CODE_CONTEXT"))
        XCTAssertTrue(result?.trace?.contains("WeChat") == true)
        XCTAssertTrue(result?.trace?.contains("messaging") == true)
        XCTAssertFalse(result?.trace?.contains("ChatGPT") == true)
    }

    func testProcessingRefreshesWeChatSnapshotToChatGPTBeforePromptAndTrace() async {
        let chatGPT = target(pid: 2102, bundleID: "com.openai.codex", name: "ChatGPT")
        let currentTarget = TargetBox(chatGPT)
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "请保留 APIClient 的大小写",
            startingSnapshot: messagingSnapshot(),
            settings: awarenessSettings(),
            currentTarget: { currentTarget.value() },
            capture: { target, settings in
                await captures.record(target)
                return capturedSnapshot(for: target, settings: settings)
            }
        )

        let prompts = await client.prompts()
        let capturedTargets = await captures.targets()
        XCTAssertEqual(capturedTargets, [chatGPT])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("当前是开发工具"))
        XCTAssertTrue(prompts[0].contains("标识符和大小写"))
        XCTAssertFalse(prompts[0].contains("当前是聊天场景"))
        XCTAssertFalse(prompts[0].contains("SYNTHETIC_WECHAT_CONTEXT"))
        XCTAssertTrue(result?.trace?.contains("ChatGPT") == true)
        XCTAssertTrue(result?.trace?.contains("development") == true)
        XCTAssertFalse(result?.trace?.contains("WeChat") == true)
    }

    func testChangingAppWhileLLMWaitsDoesNotRerunOrReplaceProcessingSnapshot() async {
        let chrome = target(pid: 2201, bundleID: "com.google.Chrome", name: "Chrome")
        let chatGPT = target(pid: 2202, bundleID: "com.openai.codex", name: "ChatGPT")
        let currentTarget = TargetBox(chrome)
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient { _ in currentTarget.set(chatGPT) }
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "请保留 APIClient 的大小写",
            startingSnapshot: messagingSnapshot(),
            settings: awarenessSettings(),
            currentTarget: { currentTarget.value() },
            capture: { target, settings in
                await captures.record(target)
                return capturedSnapshot(for: target, settings: settings)
            }
        )

        let prompts = await client.prompts()
        let capturedTargets = await captures.targets()
        XCTAssertEqual(capturedTargets, [chrome])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("当前是浏览器普通输入控件"))
        XCTAssertFalse(prompts[0].contains("当前是开发工具"))
        XCTAssertTrue(result?.trace?.contains("Chrome") == true)
        XCTAssertFalse(result?.trace?.contains("ChatGPT") == true)
    }

    func testSameAppCursorActivityCannotCauseASecondContextReadOrLLMRequest() async {
        let chatGPT = target(pid: 2301, bundleID: "com.openai.codex", name: "ChatGPT")
        let currentTarget = TargetBox(chatGPT)
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient { _ in
            // Cursor movement has no place in this policy: the production seam
            // deliberately has no AX focus or selection observation after dispatch.
            currentTarget.set(chatGPT)
        }
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "保留 MyAPIClient 的大小写",
            startingSnapshot: messagingSnapshot(),
            settings: awarenessSettings(context: true),
            currentTarget: { currentTarget.value() },
            capture: { target, settings in
                await captures.record(target)
                var snapshot = capturedSnapshot(for: target, settings: settings)
                snapshot.contextBeforeCursor = "let initialCursor = 1"
                return snapshot
            }
        )

        let capturedTargets = await captures.targets()
        let prompts = await client.prompts()
        XCTAssertEqual(capturedTargets, [chatGPT])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(result?.trace?.contains("ChatGPT") == true)
    }

    func testCaptureThatFinishesAfterAppSwitchUsesCurrentAppOnlySnapshotWithoutRetry() async {
        let chrome = target(pid: 2401, bundleID: "com.google.Chrome", name: "Chrome")
        let chatGPT = target(pid: 2402, bundleID: "com.openai.codex", name: "ChatGPT")
        let currentTarget = TargetBox(chrome)
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "请保留 APIClient 的大小写",
            startingSnapshot: messagingSnapshot(),
            settings: awarenessSettings(context: true),
            currentTarget: { currentTarget.value() },
            capture: { target, settings in
                await captures.record(target)
                currentTarget.set(chatGPT)
                return capturedSnapshot(for: target, settings: settings)
            }
        )

        let prompts = await client.prompts()
        let capturedTargets = await captures.targets()
        XCTAssertEqual(capturedTargets, [chrome])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("当前是开发工具"))
        XCTAssertFalse(prompts[0].contains("当前是浏览器普通输入控件"))
        XCTAssertTrue(result?.trace?.contains("ChatGPT") == true)
        XCTAssertTrue(result?.trace?.contains("appOnly") == true)
        XCTAssertFalse(result?.trace?.contains("Chrome") == true)
    }

    func testCaptureThatFinishesAfterSwitchIntoBlacklistUsesBlacklistedCurrentTarget() async {
        let chrome = target(pid: 2501, bundleID: "com.google.Chrome", name: "Chrome")
        let privateEditor = target(pid: 2502, bundleID: "com.example.secret", name: "Private Editor")
        let currentTarget = TargetBox(chrome)
        var settings = awarenessSettings(context: true)
        settings.blacklistedApps = [.init(bundleIdentifier: privateEditor.bundleIdentifier!, displayName: "Private Editor")]
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "一段普通文本",
            startingSnapshot: messagingSnapshot(),
            settings: settings,
            currentTarget: { currentTarget.value() },
            capture: { target, settings in
                await captures.record(target)
                currentTarget.set(privateEditor)
                return capturedSnapshot(for: target, settings: settings)
            }
        )

        let prompts = await client.prompts()
        let capturedTargets = await captures.targets()
        let prompt = try! XCTUnwrap(prompts.first)
        XCTAssertEqual(capturedTargets, [chrome])
        XCTAssertFalse(prompt.contains("# 当前输入场景"))
        XCTAssertFalse(prompt.contains("SYNTHETIC_WECHAT_CONTEXT"))
        XCTAssertTrue(result?.trace?.contains("Private Editor") == true)
        XCTAssertTrue(result?.trace?.contains("blacklisted") == true)
    }

    func testAutomationAndManualInputKeepStartingSnapshotWithoutCapture() async {
        for (isAutomation, manualInput) in [(true, false), (false, true)] {
            let chatGPT = target(pid: pid_t(2600 + (isAutomation ? 1 : 2)), bundleID: "com.openai.codex", name: "ChatGPT")
            let captures = CaptureRecorder()
            let client = PromptRecordingLLMClient()
            let session = RecognitionSession()
            await session.setInjectedLLMClientForTesting(client)

            let result = await session.processIntelliSenseForTesting(
                text: "这是一段普通测试文本",
                startingSnapshot: messagingSnapshot(),
                settings: awarenessSettings(),
                isAutomation: isAutomation,
                manualInput: manualInput,
                currentTarget: { chatGPT },
                capture: { target, settings in
                    await captures.record(target)
                    return capturedSnapshot(for: target, settings: settings)
                }
            )

            let prompts = await client.prompts()
            let capturedTargets = await captures.targets()
            XCTAssertTrue(capturedTargets.isEmpty)
            XCTAssertEqual(prompts.count, 1)
            XCTAssertTrue(prompts[0].contains("当前是聊天场景"))
            XCTAssertFalse(prompts[0].contains("当前是开发工具"))
            XCTAssertTrue(result?.trace?.contains("WeChat") == true)
        }
    }

    func testBlacklistedDestinationDoesNotPlaceContextOrSceneRulesInPrompt() async {
        let destination = target(pid: 2701, bundleID: "com.example.secret", name: "Private Editor")
        var settings = awarenessSettings(context: true)
        settings.blacklistedApps = [.init(bundleIdentifier: destination.bundleIdentifier!, displayName: "Private Editor")]
        let client = PromptRecordingLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "一段普通文本",
            startingSnapshot: messagingSnapshot(),
            settings: settings,
            currentTarget: { destination },
            capture: { target, settings in
                // Exercise the production blacklist return without accessing AX.
                await IntelliSenseContextCapturer.capture(target: target, settings: settings)
            }
        )

        let prompts = await client.prompts()
        let prompt = try! XCTUnwrap(prompts.first)
        XCTAssertFalse(prompt.contains("# 当前输入场景"))
        XCTAssertFalse(prompt.contains("SYNTHETIC_WECHAT_CONTEXT"))
        XCTAssertTrue(result?.trace?.contains("blacklisted") == true)
    }

    func testEmptyTranscriptDoesNotCaptureDestinationContext() async {
        let captures = CaptureRecorder()
        let client = PromptRecordingLLMClient()
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)

        let result = await session.processIntelliSenseForTesting(
            text: "",
            startingSnapshot: messagingSnapshot(),
            settings: awarenessSettings(),
            currentTarget: { target(pid: 2801, bundleID: "com.openai.codex", name: "ChatGPT") },
            capture: { target, settings in
                await captures.record(target)
                return capturedSnapshot(for: target, settings: settings)
            }
        )

        XCTAssertNil(result)
        let capturedTargets = await captures.targets()
        let prompts = await client.prompts()
        XCTAssertTrue(capturedTargets.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testCancelledAndExemptSpeechDoesNotCaptureOrCallLLM() async {
        for (cancelled, exemption) in [(true, 0), (false, 100)] {
            let captures = CaptureRecorder()
            let client = PromptRecordingLLMClient()
            let session = RecognitionSession()
            await session.setInjectedLLMClientForTesting(client)
            let result = await session.processIntelliSenseForTesting(
                text: "简单测试",
                startingSnapshot: messagingSnapshot(),
                settings: awarenessSettings(),
                cancelled: cancelled,
                shortTextExemption: exemption,
                currentTarget: { target(pid: 2901, bundleID: "com.google.Chrome", name: "Chrome") },
                capture: { target, settings in
                    await captures.record(target)
                    return capturedSnapshot(for: target, settings: settings)
                }
            )
            let capturedTargets = await captures.targets()
            let prompts = await client.prompts()
            XCTAssertTrue(capturedTargets.isEmpty)
            XCTAssertTrue(prompts.isEmpty)
            XCTAssertEqual(result?.text, "简单测试")
        }
    }

    private func awarenessSettings(context: Bool = false) -> IntelliSenseSettings {
        IntelliSenseSettings(
            applicationAwarenessEnabled: true,
            contextAwarenessEnabled: context,
            correctionDetectionEnabled: false,
            expressionLearningEnabled: false
        )
    }

    private func messagingSnapshot() -> IntelliSenseContextSnapshot {
        IntelliSenseContextSnapshot(
            bundleIdentifier: "com.tencent.xinWeChat",
            appName: "WeChat",
            appCategory: .messaging,
            controlCategory: .multiLine,
            contextBeforeCursor: "SYNTHETIC_WECHAT_CONTEXT",
            contextAfterCursor: "",
            availability: .appAndControl,
            wasTruncated: false
        )
    }

    private func developmentSnapshot() -> IntelliSenseContextSnapshot {
        IntelliSenseContextSnapshot(
            bundleIdentifier: "com.openai.codex",
            appName: "ChatGPT",
            appCategory: .development,
            controlCategory: .code,
            contextBeforeCursor: "SYNTHETIC_CODE_CONTEXT",
            contextAfterCursor: "",
            availability: .appAndControl,
            wasTruncated: false
        )
    }
}

private func target(pid: pid_t, bundleID: String, name: String) -> TargetApplicationContext {
    TargetApplicationContext(processIdentifier: pid, bundleIdentifier: bundleID, displayName: name)
}

private func capturedSnapshot(
    for target: TargetApplicationContext,
    settings: IntelliSenseSettings
) -> IntelliSenseContextSnapshot {
    IntelliSenseContextSnapshot(
        bundleIdentifier: target.bundleIdentifier,
        appName: target.displayName,
        appCategory: AppContextClassifier.classify(
            bundleIdentifier: target.bundleIdentifier,
            appName: target.displayName
        ),
        controlCategory: .multiLine,
        contextBeforeCursor: "",
        contextAfterCursor: "",
        availability: .appAndControl,
        wasTruncated: false
    )
}

private final class TargetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var target: TargetApplicationContext

    init(_ target: TargetApplicationContext) {
        self.target = target
    }

    func value() -> TargetApplicationContext {
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    func set(_ target: TargetApplicationContext) {
        lock.lock()
        self.target = target
        lock.unlock()
    }
}

private actor CaptureRecorder {
    private var recordedTargets: [TargetApplicationContext] = []

    func record(_ target: TargetApplicationContext) {
        recordedTargets.append(target)
    }

    func targets() -> [TargetApplicationContext] {
        recordedTargets
    }
}

private actor PromptRecordingLLMClient: LLMClient {
    private var recordedPrompts: [String] = []
    private let afterProcess: (@Sendable (Int) -> Void)?

    init(afterProcess: (@Sendable (Int) -> Void)? = nil) {
        self.afterProcess = afterProcess
    }

    func process(
        text: String,
        prompt: String,
        config: LLMConfig,
        inputBoundary: LLMInputBoundary
    ) async throws -> String {
        recordedPrompts.append(prompt)
        afterProcess?(recordedPrompts.count)
        return text
    }

    func prompts() -> [String] {
        recordedPrompts
    }

    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
