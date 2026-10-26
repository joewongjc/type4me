import XCTest
@testable import Type4Me

final class FakeReviseAccessibilityClient: ReviseAccessibilityClient, @unchecked Sendable {
    var snapshot: ReviseFocusedControlSnapshot
    var currentValue: String
    var currentSelectedRange: NSRange?
    var selectedTextSettable: Bool = true
    var selectedTextApplies: Bool = true
    var pasteboard: NSPasteboard = .general
    var pasteHandler: (() -> Void)?

    init(
        element: AXUIElement,
        pid: pid_t = 1234,
        bundleID: String = "com.apple.TextEdit",
        initialValue: String = "Hello World",
        isEditable: Bool = true,
        isSecure: Bool = false,
        supportsSingleLineOnly: Bool = false
    ) {
        self.snapshot = ReviseFocusedControlSnapshot(
            element: element,
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            role: "AXTextArea",
            subrole: nil,
            value: initialValue,
            placeholder: nil,
            selectedRange: nil,
            placeholderCandidates: [],
            isEditable: isEditable,
            isSecure: isSecure,
            supportsSingleLineOnly: supportsSingleLineOnly
        )
        self.currentValue = initialValue
    }

    func focusedControl() throws -> ReviseFocusedControlSnapshot {
        ReviseFocusedControlSnapshot(
            element: snapshot.element,
            processIdentifier: snapshot.processIdentifier,
            bundleIdentifier: snapshot.bundleIdentifier,
            role: snapshot.role,
            subrole: snapshot.subrole,
            value: currentValue,
            placeholder: snapshot.placeholder,
            selectedRange: currentSelectedRange,
            placeholderCandidates: snapshot.placeholderCandidates,
            isEditable: snapshot.isEditable,
            isSecure: snapshot.isSecure,
            supportsSingleLineOnly: snapshot.supportsSingleLineOnly
        )
    }

    func value(of element: AXUIElement) throws -> String {
        currentValue
    }

    func selectedRange(of element: AXUIElement) throws -> NSRange? {
        currentSelectedRange
    }

    func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        if attribute == (kAXSelectedTextAttribute as CFString) {
            return selectedTextSettable
        }
        return true
    }

    func setSelectedRange(_ range: NSRange, on element: AXUIElement) throws {
        currentSelectedRange = range
    }

    func setSelectedText(_ text: String, on element: AXUIElement) throws {
        guard selectedTextApplies else { return }
        guard let range = currentSelectedRange else { return }
        let ns = currentValue as NSString
        currentValue = ns.replacingCharacters(in: range, with: text)
    }

    func pressDelete() throws {
        guard let range = currentSelectedRange else { return }
        let ns = currentValue as NSString
        currentValue = ns.replacingCharacters(in: range, with: "")
    }

    func paste() throws {
        if let handler = pasteHandler {
            handler()
            return
        }
        guard let range = currentSelectedRange, let text = pasteboard.string(forType: .string) else { return }
        let ns = currentValue as NSString
        currentValue = ns.replacingCharacters(in: range, with: text)
    }
}

final class TrackedTextReplacementEngineTests: XCTestCase {
    private var dummyElement: AXUIElement!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dummyElement = AXUIElementCreateSystemWide()
    }

    func testSuccessfulDirectSelectedTextReplace() async throws {
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            initialValue: "明天下午三点和 Jerry 开会。"
        )
        fakeAX.selectedTextSettable = true

        let engine = TrackedTextReplacementEngine(accessibilityClient: fakeAX)
        let req = TrackedTextReplacementRequest(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            expectedFullValue: "明天下午三点和 Jerry 开会。",
            expectedRange: NSRange(location: 4, length: 2), // "三点"
            expectedText: "三点",
            replacementText: "四点"
        )

        let result = await engine.replace(req)
        guard case .success(let success) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        XCTAssertEqual(success.afterFullValue, "明天下午四点和 Jerry 开会。")
        XCTAssertEqual(fakeAX.currentValue, "明天下午四点和 Jerry 开会。")
        XCTAssertEqual(success.replacementRange, NSRange(location: 4, length: 2))
    }

    func testSuccessfulDeleteToEmpty() async throws {
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            initialValue: "明天下午三点和 Jerry 开会。"
        )
        fakeAX.selectedTextSettable = false

        let engine = TrackedTextReplacementEngine(accessibilityClient: fakeAX)
        let req = TrackedTextReplacementRequest(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            expectedFullValue: "明天下午三点和 Jerry 开会。",
            expectedRange: NSRange(location: 14, length: 3), // "开会。"
            expectedText: "开会。",
            replacementText: ""
        )

        let result = await engine.replace(req)
        guard case .success(let success) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }

        XCTAssertEqual(success.afterFullValue, "明天下午三点和 Jerry ")
    }

    func testSelectedTextNoOpFallsBackToPaste() async throws {
        let original = "明天上午 9 点开会，讨论这个项目的进度"
        let replacement = "明天下午 2 点开会，讨论这个项目的进度"
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            bundleID: "com.electron.lark",
            initialValue: original
        )
        fakeAX.currentSelectedRange = NSRange(location: (original as NSString).length, length: 0)
        fakeAX.selectedTextSettable = true
        fakeAX.selectedTextApplies = false

        let engine = TrackedTextReplacementEngine(accessibilityClient: fakeAX)
        let req = TrackedTextReplacementRequest(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.electron.lark",
            expectedFullValue: original,
            expectedRange: NSRange(location: 0, length: (original as NSString).length),
            expectedText: original,
            replacementText: replacement
        )

        let result = await engine.replace(req)

        guard case .success(let success) = result else {
            XCTFail("Expected paste fallback success, got \(result)")
            return
        }
        XCTAssertEqual(success.afterFullValue, replacement)
        XCTAssertEqual(fakeAX.currentValue, replacement)
    }

    func testFailedFallbackRestoresOriginalSelection() async throws {
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            bundleID: "com.electron.lark",
            initialValue: "明天上午 9 点开会"
        )
        let originalSelection = NSRange(location: 10, length: 0)
        fakeAX.currentSelectedRange = originalSelection
        fakeAX.selectedTextSettable = true
        fakeAX.selectedTextApplies = false
        fakeAX.pasteHandler = {}

        let engine = TrackedTextReplacementEngine(accessibilityClient: fakeAX)
        let req = TrackedTextReplacementRequest(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.electron.lark",
            expectedFullValue: "明天上午 9 点开会",
            expectedRange: NSRange(location: 0, length: 10),
            expectedText: "明天上午 9 点开会",
            replacementText: "明天下午 2 点开会"
        )

        let result = await engine.replace(req)

        guard case .failure(let failure) = result else {
            XCTFail("Expected no-change failure, got \(result)")
            return
        }
        XCTAssertEqual(failure, .noChange)
        XCTAssertEqual(fakeAX.currentSelectedRange, originalSelection)
    }

    func testValueChangedBeforeWriteFails() async throws {
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            initialValue: "明天下午三点和 Jerry 开会。"
        )

        let engine = TrackedTextReplacementEngine(accessibilityClient: fakeAX)
        let req = TrackedTextReplacementRequest(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            expectedFullValue: "旧的完整内容",
            expectedRange: NSRange(location: 0, length: 2),
            expectedText: "旧的",
            replacementText: "新的"
        )

        let result = await engine.replace(req)
        guard case .failure(let err) = result else {
            XCTFail("Expected failure for valueChangedBeforeWrite")
            return
        }
        XCTAssertEqual(err, .valueChangedBeforeWrite)
    }

    func testSingleLineNewlineViolationFails() async throws {
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            initialValue: "单行标题",
            supportsSingleLineOnly: true
        )

        let engine = TrackedTextReplacementEngine(accessibilityClient: fakeAX)
        let req = TrackedTextReplacementRequest(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            expectedFullValue: "单行标题",
            expectedRange: NSRange(location: 0, length: 4),
            expectedText: "单行标题",
            replacementText: "单行\n标题"
        )

        let result = await engine.replace(req)
        guard case .failure(let err) = result else {
            XCTFail("Expected failure for singleLineViolation")
            return
        }
        XCTAssertEqual(err, .singleLineViolation)
    }
}
