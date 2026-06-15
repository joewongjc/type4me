import XCTest
@testable import Type4Me

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
        UserDefaults.standard.removeObject(forKey: "tf_preserveCJKLatinSpacing")
    }

    func testInitialStateIsIdle() async {
        let session = RecognitionSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSetState() async {
        let session = RecognitionSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = RecognitionSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForSoniox() async {
        KeychainService.selectedASRProvider = .soniox
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testShouldAttemptBatchFallbackWhenStreamingErrorWasObserved() {
        let shouldFallback = RecognitionSession.shouldAttemptBatchFallback(
            uploadFailed: false,
            asrTeardownClean: true,
            streamingError: DeepgramASRError.closed(code: 1008, reason: "policy violation")
        )

        XCTAssertTrue(shouldFallback)
    }

    // MARK: - CJK / Latin spacing (issue #186)

    /// The space between a CJK character and an adjacent Latin word or digit
    /// (Pangu spacing) must survive normalization. Regression test for #186,
    /// where "我已经把最新的 prompt 提交并更新" was collapsed to "...的prompt提交...".
    func testRemovingCJKLatinSpaces_preservesPanguSpacing() {
        UserDefaults.standard.set(true, forKey: "tf_preserveCJKLatinSpacing")

        // The reported case: CJK ↔ Latin spaces are kept.
        XCTAssertEqual(
            "我已经把最新的 prompt 提交并更新".removingCJKLatinSpaces,
            "我已经把最新的 prompt 提交并更新"
        )
        // CJK ↔ Latin word, both boundaries.
        XCTAssertEqual("Max 你好".removingCJKLatinSpaces, "Max 你好")
        XCTAssertEqual("发布 v1.9.5 版本".removingCJKLatinSpaces, "发布 v1.9.5 版本")
        // CJK ↔ digit.
        XCTAssertEqual("第 3 个".removingCJKLatinSpaces, "第 3 个")
        // Pure English is untouched.
        XCTAssertEqual("hello world".removingCJKLatinSpaces, "hello world")
    }

    /// Spaces between two CJK characters, or between a CJK character and
    /// punctuation, are ASR/LLM noise and must still be removed.
    func testRemovingCJKLatinSpaces_stripsCJKAndPunctuationNoise() {
        UserDefaults.standard.set(true, forKey: "tf_preserveCJKLatinSpacing")

        // CJK ↔ CJK noise from ASR token boundaries.
        XCTAssertEqual("你 好".removingCJKLatinSpaces, "你好")
        XCTAssertEqual("你  好".removingCJKLatinSpaces, "你好")
        // CJK ↔ punctuation (full-width and ASCII).
        XCTAssertEqual("你好 ，世界".removingCJKLatinSpaces, "你好，世界")
        XCTAssertEqual("你好 , 世界".removingCJKLatinSpaces, "你好,世界")
    }

    func testRemovingCJKLatinSpaces_canStripPanguSpacingWhenDisabled() {
        UserDefaults.standard.set(false, forKey: "tf_preserveCJKLatinSpacing")

        XCTAssertEqual(
            "我已经把最新的 prompt 提交并更新".removingCJKLatinSpaces,
            "我已经把最新的prompt提交并更新"
        )
        XCTAssertEqual("第 3 个".removingCJKLatinSpaces, "第3个")
    }
}
