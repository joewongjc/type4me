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

    func testExpandContextVariables_singlePassDoesNotExpandUserContent() {
        let ctx = PromptContext(selectedText: "{clipboard}", clipboardText: "secret")
        let result = ctx.expandContextVariables("Selected={selected}")
        XCTAssertEqual(result, "Selected={clipboard}")
    }

    func testSelectionAskPromptIncludesSelectedTextAndPreservesQuestionPlaceholder() {
        let ctx = PromptContext(selectedText: "Update Keychain partition lists", clipboardText: "")
        let prompt = SelectionAskPromptBuilder.requestText(mode: .selectionAsk, context: ctx)

        XCTAssertTrue(prompt.contains("Update Keychain partition lists"))
        XCTAssertFalse(prompt.contains("{selected}"))
        XCTAssertTrue(prompt.contains("{text}"))
    }

    func testSelectionAskPromptKeepsTextPlaceholderInsideSelectionLiteral() {
        let ctx = PromptContext(selectedText: "literal {text}", clipboardText: "")
        let prompt = SelectionAskPromptBuilder.requestText(mode: .selectionAsk, context: ctx, question: "翻译成中文")

        XCTAssertTrue(prompt.contains("literal {text}"))
        XCTAssertTrue(prompt.contains("翻译成中文"))
    }

    func testSelectionAskPromptIncludesConversationContext() {
        let ctx = PromptContext(selectedText: "A selected paragraph", clipboardText: "")
        let prompt = SelectionAskPromptBuilder.requestText(
            mode: .selectionAsk,
            context: ctx,
            question: "那下一步怎么做？",
            conversationContext: "用户：这段什么意思？\n助手：这是发布说明。"
        )

        XCTAssertTrue(prompt.contains("用户：这段什么意思？"))
        XCTAssertTrue(prompt.contains("那下一步怎么做？"))
        XCTAssertFalse(prompt.contains("{conversation}"))
    }

    func testSelectionAskCustomPromptAppendsConversationContext() {
        let custom = ProcessingMode(
            id: UUID(),
            name: "Custom Ask",
            prompt: "Question={text}\nSelection={selected}",
            isBuiltin: false
        )
        let ctx = PromptContext(selectedText: "Selected", clipboardText: "")
        let prompt = SelectionAskPromptBuilder.requestText(
            mode: custom,
            context: ctx,
            question: "继续解释",
            conversationContext: "上一轮回答"
        )

        XCTAssertTrue(prompt.contains("Question=继续解释"))
        XCTAssertTrue(prompt.contains("# 上方会话上下文"))
        XCTAssertTrue(prompt.contains("上一轮回答"))
    }

    func testSelectionAskEmptySelectionIsDetectedBeforeRequest() {
        let ctx = PromptContext(selectedText: " \n\t ", clipboardText: "")
        XCTAssertEqual(SelectionAskPromptBuilder.contextText(from: ctx), "")
    }

    func testSelectionAskDoesNotFallBackToClipboardWhenSelectionIsEmpty() {
        let ctx = PromptContext(selectedText: " \n\t ", clipboardText: "clipboard text")
        XCTAssertEqual(SelectionAskPromptBuilder.contextText(from: ctx), "")
    }

    func testSelectionAskDoesNotFallBackToClipboardWhenSelectionIsPlaceholder() {
        let ctx = PromptContext(selectedText: "selection", clipboardText: "clipboard text")
        XCTAssertEqual(SelectionAskPromptBuilder.contextText(from: ctx), "")
    }

    func testMarkdownRendererPreservesSoftLineBreaksOutsideCodeFence() {
        let markdown = "第一行\n第二行\n\n```swift\nlet a = 1\nlet b = 2\n```"
        let normalized = MarkdownRenderer.preserveSoftLineBreaks(in: markdown)
        XCTAssertTrue(normalized.contains("第一行  \n第二行"))
        XCTAssertTrue(normalized.contains("let a = 1\nlet b = 2"))
    }

    func testMarkdownRendererSplitsLongPlainParagraphs() {
        let markdown = "这是第一句话，包含足够多的背景信息，用来模拟模型输出的一整段长回答。这里继续解释很多内容，因此应该拆开，避免所有内容挤在一个段落里。最后一句继续补充细节，让整个段落超过拆分阈值。这里再补充一段较长说明，确保测试样本稳定超过阈值，并且继续加入一些自然语言内容来覆盖字符计数差异。"
        let blocks = MarkdownRenderer.displayBlocks(from: markdown)
        XCTAssertGreaterThan(blocks.count, 1)
    }

    func testMarkdownRendererFallsBackForPlainText() {
        let rendered = MarkdownRenderer.attributedString(from: "**回答**\n\n- A")
        XCTAssertFalse(String(rendered.characters).isEmpty)
    }
}
