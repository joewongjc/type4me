import XCTest
@testable import Type4Me

final class UserEditObservationLifecycleTests: XCTestCase {
    func testAccessibilityValueEqualToPlaceholderIsTreatedAsCleared() {
        let result = UserEditObservedValueSanitizer.contentValue(
            "发送给 Quentin Chen（陈坤）的智能伙伴",
            placeholderCandidates: ["发送给 Quentin Chen（陈坤）的智能伙伴", nil]
        )

        XCTAssertEqual(result, "")
    }

    func testPlaceholderComparisonNormalizesWhitespaceAndUnicode() {
        let result = UserEditObservedValueSanitizer.contentValue(
            "  发送消息\n",
            placeholderCandidates: ["发送消息"]
        )

        XCTAssertEqual(result, "")
    }

    func testRealTextIsNotDiscardedWhenItDiffersFromPlaceholder() {
        let result = UserEditObservedValueSanitizer.contentValue(
            "我晚上找安吉问一下吧",
            placeholderCandidates: ["发送给 Quentin Chen（陈坤）的智能伙伴"]
        )

        XCTAssertEqual(result, "我晚上找安吉问一下吧")
    }

    func testEmptyPlaceholderMetadataDoesNotDiscardRealText() {
        let result = UserEditObservedValueSanitizer.contentValue(
            "发送消息",
            placeholderCandidates: [nil, ""]
        )

        XCTAssertEqual(result, "发送消息")
    }

    func testElectronBoundarySentinelAndNewlineAreNotAUserEdit() {
        let original = "嗯，可以，那我们明天下午 3 点见"
        let observed = original + "\u{200B}\n"

        let settlement = UserEditObservationSettlement.resolve(
            original: original,
            lastReliableText: observed,
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .nextRecording
        )

        XCTAssertNil(settlement.text)
        XCTAssertEqual(settlement.status, .unchanged)
    }

    func testVisibleProjectionPreservesOrdinaryTrailingNewlineAndTab() {
        let value = "第一行\n\t第二行"

        XCTAssertEqual(VisibleTextProjection.project(value).text, value)
    }

    func testVisibleProjectionDropsEditorSentinelsAndOrdinaryControls() {
        let value = "Type\u{200B}4\u{FEFF}Me\u{2060}\u{0001}"

        XCTAssertEqual(VisibleTextProjection.project(value).text, "Type4Me")
    }

    func testVisibleProjectionPreservesEmojiJoinerVariationAndBidirectionalFormatting() {
        let value = "👨‍👩‍👧‍👦 ✈️ \u{2067}مرحبا\u{2069}"

        XCTAssertEqual(VisibleTextProjection.project(value).text, value)
    }

    func testVisibleProjectionNormalizesLineEndingsAndCanonicalComposition() {
        let value = "cafe\u{301}\r\n下一行\r末行"

        XCTAssertEqual(VisibleTextProjection.project(value).text, "café\n下一行\n末行")
    }

    func testVisibleProjectionMapsUTF16InjectedRangeAfterIgnoredCharacters() throws {
        let source = "🙂 pre\u{200B}Ghostty suffix"
        let sourceRange = try range(of: "Ghostty", in: source)
        let projection = VisibleTextProjection.project(source)
        let projectedRange = try XCTUnwrap(projection.projectedRange(from: sourceRange))

        XCTAssertEqual(projection.text, "🙂 preGhostty suffix")
        XCTAssertEqual((projection.text as NSString).substring(with: projectedRange), "Ghostty")
    }

    func testInvisibleOnlyAXChangeLeavesVisibleStateUnchanged() {
        let injected = "Type4Me output"
        let current = VisibleTextProjection.project(injected + "\u{200B}\u{0001}").text

        XCTAssertEqual(UserEditVisibleStateMachine.classify(
            currentVisibleValue: current,
            isPlaceholder: false,
            baselineVisibleValue: injected,
            visibleInjectedRange: NSRange(
                location: 0,
                length: (injected as NSString).length
            ),
            visibleInjectedText: injected,
            lastReliableVisibleInjectedText: injected,
            previousVisibleFullValue: injected
        ), .unchanged)
    }

    func testEmptyVisibleValueEndsObservationImmediately() {
        let injected = "Type4Me output"

        XCTAssertEqual(UserEditVisibleStateMachine.classify(
            currentVisibleValue: "",
            isPlaceholder: false,
            baselineVisibleValue: injected,
            visibleInjectedRange: NSRange(
                location: 0,
                length: (injected as NSString).length
            ),
            visibleInjectedText: injected,
            lastReliableVisibleInjectedText: injected,
            previousVisibleFullValue: injected
        ), .valueCleared)
    }

    func testPlaceholderEndsObservationAsStructuralChange() {
        let injected = "Type4Me output"

        XCTAssertEqual(UserEditVisibleStateMachine.classify(
            currentVisibleValue: "",
            isPlaceholder: true,
            baselineVisibleValue: injected,
            visibleInjectedRange: NSRange(
                location: 0,
                length: (injected as NSString).length
            ),
            visibleInjectedText: injected,
            lastReliableVisibleInjectedText: injected,
            previousVisibleFullValue: injected
        ), .structureChanged)
    }

    func testStructuralResetDetectsPlaceholderWithoutMetadataForExistingContent() throws {
        let baseline = "已有内容 我晚上找安吉问一下吧 后续内容"
        let injected = "我晚上找安吉问一下吧"

        XCTAssertTrue(UserEditControlResetDetector.isLikelyReset(
            baselineValue: baseline,
            injectedRange: try range(of: injected, in: baseline),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: baseline,
            currentValue: "发送给 Quentin Chen（陈坤）的智能伙伴"
        ))
    }

    func testStructuralResetDetectsWholeFieldReset() {
        let injected = "我晚上找安吉问一下吧"

        XCTAssertTrue(UserEditControlResetDetector.isLikelyReset(
            baselineValue: injected,
            injectedRange: NSRange(location: 0, length: (injected as NSString).length),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: injected,
            currentValue: "发送给 Quentin Chen（陈坤）的智能伙伴"
        ))
    }

    func testStructuralResetEndsOnAtomicWholeFieldRewrite() {
        let injected = "我晚上找安吉问一下吧"
        let rewrite = "我改成明天再联系"

        XCTAssertTrue(UserEditControlResetDetector.isLikelyReset(
            baselineValue: injected,
            injectedRange: NSRange(location: 0, length: (injected as NSString).length),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: injected,
            currentValue: rewrite
        ))
    }

    func testStructuralResetDoesNotRequireReadableCaretTransition() {
        let injected = "我晚上找安吉问一下吧"

        XCTAssertTrue(UserEditControlResetDetector.isLikelyReset(
            baselineValue: injected,
            injectedRange: NSRange(location: 0, length: (injected as NSString).length),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: injected,
            currentValue: "发送给 Quentin Chen（陈坤）的智能伙伴"
        ))
    }

    func testStructuralResetDoesNotDiscardEditThatRetainsExternalAnchors() throws {
        let baseline = "已有内容 我晚上找安吉问一下吧 后续内容"
        let injected = "我晚上找安吉问一下吧"

        XCTAssertFalse(UserEditControlResetDetector.isLikelyReset(
            baselineValue: baseline,
            injectedRange: try range(of: injected, in: baseline),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: baseline,
            currentValue: "已有内容 我改成明天再联系 后续内容"
        ))
    }

    func testResetDetectsFieldReturningToPreexistingPrefix() throws {
        let injected = "这是追加语音发送测试二"
        let baseline = "已有内容：\(injected)"

        XCTAssertTrue(UserEditControlResetDetector.isLikelyReset(
            baselineValue: baseline,
            injectedRange: try range(of: injected, in: baseline),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: baseline,
            currentValue: "已有内容："
        ))
    }

    func testResetDetectsLarkCompositePlaceholderWithoutMetadataOrCaret() {
        let injected = "我明天上午参加测试4"

        XCTAssertTrue(UserEditControlResetDetector.isLikelyReset(
            baselineValue: injected,
            injectedRange: NSRange(location: 0, length: (injected as NSString).length),
            injectedText: injected,
            lastReliableInjectedText: injected,
            previousFullValue: injected,
            currentValue: "发送给 Sean Huang（黄晓）\n\n会议中\n"
        ))
    }

    func testStructuralResetRequiresMoreThanSeventyPercentChange() {
        XCTAssertEqual(
            UserEditControlResetDetector.normalizedChangeRatio(
                previous: "abcdefghij",
                current: "abcXYZghij"
            ),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            UserEditControlResetDetector.normalizedChangeRatio(
                previous: "abcdefghij",
                current: "XYZ"
            ),
            1,
            accuracy: 0.0001
        )
    }

    func testSmallWholeFieldEditRemainsContinuous() {
        let original = "abcdefghij"

        XCTAssertFalse(UserEditControlResetDetector.isLikelyReset(
            baselineValue: original,
            injectedRange: NSRange(
                location: 0,
                length: (original as NSString).length
            ),
            injectedText: original,
            lastReliableInjectedText: original,
            previousFullValue: original,
            currentValue: "abcXYZghij"
        ))
    }

    func testStructureChangeKeepsLastReliableVisibleEdit() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "ghosty",
            lastReliableText: "Ghostty",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .structureChanged
        )

        XCTAssertEqual(settlement.text, "Ghostty")
        XCTAssertEqual(settlement.status, .edited)
    }

    func testVisibleLineBreakChangeIsPersisted() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "第一行 第二行",
            lastReliableText: "第一行\n第二行",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .nextRecording
        )

        XCTAssertEqual(settlement.text, "第一行\n第二行")
        XCTAssertEqual(settlement.status, .edited)
    }

    func testResetAfterRealEditKeepsLastReliableEditAtSettlement() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "我今天会和杰瑞确认测试3",
            lastReliableText: "我今天会和 Jerry 确认测试3",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .valueCleared
        )

        XCTAssertEqual(settlement.text, "我今天会和 Jerry 确认测试3")
        XCTAssertEqual(settlement.status, .clearedAfterEdit)
    }

    func testClearedAfterEditKeepsLastReliableText() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "ghosty",
            lastReliableText: "Ghostty",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .valueCleared
        )

        XCTAssertEqual(settlement.text, "Ghostty")
        XCTAssertEqual(settlement.status, .clearedAfterEdit)
    }

    func testRestoringOriginalTextSettlesAsUnchanged() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "ghosty",
            lastReliableText: "ghosty",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .timeout
        )

        XCTAssertNil(settlement.text)
        XCTAssertEqual(settlement.status, .unchanged)
    }

    func testAmbiguousExternalChangeNeverPersistsFullControlValue() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "Type4Me output",
            lastReliableText: "Type4Me output",
            latestResolutionConfidence: .ambiguous,
            hasObservedExternalChanges: true,
            endReason: .nextRecording
        )

        XCTAssertNil(settlement.text)
        XCTAssertEqual(settlement.status, .ambiguous)
    }

    func testSensitiveEditIsRedacted() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "token abcdefghijklmnop1234",
            lastReliableText: "token abcdefghijklmnop12345",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: true,
            endReason: .timeout
        )

        XCTAssertNil(settlement.text)
        XCTAssertEqual(settlement.status, .sensitiveRedacted)
    }

    func testInitialReadFailureSettlesAsUnavailable() {
        let settlement = UserEditObservationSettlement.resolve(
            original: "ghosty",
            lastReliableText: "ghosty",
            latestResolutionConfidence: .exact,
            hasObservedExternalChanges: false,
            endReason: .readFailure
        )

        XCTAssertNil(settlement.text)
        XCTAssertEqual(settlement.status, .unavailable)
    }

    private func range(of substring: String, in text: String) throws -> NSRange {
        guard let range = text.range(of: substring) else {
            throw NSError(domain: "UserEditObservationLifecycleTests", code: 1)
        }
        return NSRange(range, in: text)
    }
}
