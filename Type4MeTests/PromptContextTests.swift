import XCTest
@testable import Type4Me

final class PromptContextTests: XCTestCase {

    func testExpandContextVariables_replacesSelected() {
        let ctx = PromptContext(selectedText: "hello world", clipboardText: "")
        let result = ctx.expandContextVariables("Fix: {selected}")
        XCTAssertEqual(result, "Fix: hello world")
    }

    func testExpandContextVariables_replacesClipboard() {
        let ctx = PromptContext(selectedText: "", clipboardText: "from clipboard")
        let result = ctx.expandContextVariables("Paste: {clipboard}")
        XCTAssertEqual(result, "Paste: from clipboard")
    }

    func testExpandContextVariables_replacesBoth() {
        let ctx = PromptContext(selectedText: "sel", clipboardText: "clip")
        let result = ctx.expandContextVariables("Selected={selected} Clipboard={clipboard} Text={text}")
        XCTAssertEqual(result, "Selected=sel Clipboard=clip Text={text}")
    }

    func testExpandContextVariables_noVariables() {
        let ctx = PromptContext(selectedText: "sel", clipboardText: "clip")
        let result = ctx.expandContextVariables("Plain prompt without variables")
        XCTAssertEqual(result, "Plain prompt without variables")
    }

    func testExpandContextVariables_emptyContext() {
        let ctx = PromptContext(selectedText: "", clipboardText: "")
        let result = ctx.expandContextVariables("A={selected} B={clipboard}")
        XCTAssertEqual(result, "A= B=")
    }

    func testExpandContextVariables_multipleOccurrences() {
        let ctx = PromptContext(selectedText: "X", clipboardText: "Y")
        let result = ctx.expandContextVariables("{selected}+{selected} {clipboard}+{clipboard}")
        XCTAssertEqual(result, "X+X Y+Y")
    }

    func testExpandContextVariables_preservesTextPlaceholder() {
        // {text} should NOT be expanded by expandContextVariables — that's the LLM client's job
        let ctx = PromptContext(selectedText: "sel", clipboardText: "clip")
        let result = ctx.expandContextVariables("修正以下文本：{text}")
        XCTAssertEqual(result, "修正以下文本：{text}")
    }
}
