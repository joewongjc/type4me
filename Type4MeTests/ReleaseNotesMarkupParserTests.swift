import XCTest
@testable import Type4Me

final class ReleaseNotesMarkupParserTests: XCTestCase {

    func testParsesMarkdownAndHTMLImage() throws {
        let blocks = ReleaseNotesMarkupParser.blocks(from: """
        ### 新功能

        - **历史与用量看板**：支持 Markdown。
        <p align="center">
        <img src="https://example.com/chart.png" width="900" alt="Usage chart" />
        </p>
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case .markdown(let markdown) = blocks[0] else {
            return XCTFail("Expected the Markdown text block first")
        }
        XCTAssertTrue(markdown.contains("### 新功能"))
        XCTAssertTrue(markdown.contains("**历史与用量看板**"))

        guard case .image(let url, let altText) = blocks[1] else {
            return XCTFail("Expected the HTML image block second")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/chart.png")
        XCTAssertEqual(altText, "Usage chart")
    }

    func testConvertsCommonHTMLBlocksToMarkdown() {
        let blocks = ReleaseNotesMarkupParser.blocks(from: "<h2>Fixes</h2><p>Line one<br>Line two &amp; more</p>")

        guard case .markdown(let markdown) = blocks.first else {
            return XCTFail("Expected a Markdown text block")
        }
        XCTAssertTrue(markdown.contains("## Fixes"))
        XCTAssertTrue(markdown.contains("Line one\nLine two & more"))
    }

    func testPreservesSourceLineBreaksInMarkdownBlock() {
        let blocks = ReleaseNotesMarkupParser.blocks(from: "### Fixes\n\n- **First**\n- **Second**")

        guard case .markdown(let markdown) = blocks.first else {
            return XCTFail("Expected a Markdown text block")
        }
        XCTAssertEqual(markdown, "### Fixes\n\n- **First**\n- **Second**")
    }
}
