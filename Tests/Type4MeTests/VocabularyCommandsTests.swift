import XCTest
@testable import Type4Me

final class VocabularyURLCommandParserTests: XCTestCase {
    private let schemes: Set<String> = ["type4me", "type4me-dev", "type4me-ctrixin"]

    func testOpenHotwordsWithoutParameters() throws {
        let command = try parse("type4me://vocabulary/hotwords")
        XCTAssertEqual(command.section, .hotwords)
        XCTAssertNil(command.word)
        XCTAssertFalse(command.silent)
    }

    func testPrefillsPercentEncodedChineseHotwordInDevScheme() throws {
        let command = try parse("type4me-dev://vocabulary/hotwords?word=%E9%98%B6%E8%B7%83%E6%98%9F%E8%BE%B0")
        XCTAssertEqual(command.word, "阶跃星辰")
        XCTAssertFalse(command.silent)
    }

    func testSilentHotwordAcceptsTrueAndOne() throws {
        XCTAssertTrue(try parse("type4me://vocabulary/hotwords?word=Ghostty&silent=true").silent)
        XCTAssertTrue(try parse("type4me://vocabulary/hotwords?word=Ghostty&silent=1").silent)
    }

    func testSnippetAllowsPartialDraftForInteractiveNavigation() throws {
        let command = try parse("type4me://vocabulary/snippets?trigger=ghosty")
        XCTAssertEqual(command.section, .snippets)
        XCTAssertEqual(command.trigger, "ghosty")
        XCTAssertNil(command.replacement)
        XCTAssertEqual(command.navigationRequest.focus, .snippetReplacement)
    }

    func testSilentSnippetRequiresBothFields() {
        assertFailure(
            "type4me://vocabulary/snippets?trigger=ghosty&silent=true",
            equals: .missingRequiredParameter
        )
    }

    func testRejectsUnknownPathSchemeAndParameter() {
        assertFailure("other://vocabulary/hotwords", equals: .unsupportedScheme)
        assertFailure("type4me://vocabulary/unknown", equals: .invalidPath)
        assertFailure("type4me://vocabulary/hotwords?value=x", equals: .unsupportedParameter)
    }

    func testRejectsDuplicateEmptyControlAndOversizedValues() {
        assertFailure(
            "type4me://vocabulary/hotwords?word=one&word=two",
            equals: .duplicateParameter
        )
        assertFailure("type4me://vocabulary/hotwords?word=%20", equals: .invalidValue)
        assertFailure("type4me://vocabulary/hotwords?word=one%0Atwo", equals: .invalidValue)
        let longWord = String(repeating: "a", count: VocabularyURLCommandParser.maximumTermLength + 1)
        assertFailure("type4me://vocabulary/hotwords?word=\(longWord)", equals: .invalidValue)
    }

    func testRejectsInvalidSilentValueAndOversizedURL() {
        assertFailure(
            "type4me://vocabulary/hotwords?word=Ghostty&silent=yes",
            equals: .invalidSilentValue
        )
        let oversized = String(repeating: "a", count: VocabularyURLCommandParser.maximumURLBytes)
        assertFailure("type4me://vocabulary/hotwords?word=\(oversized)", equals: .urlTooLong)
    }

    private func parse(_ raw: String) throws -> VocabularyURLCommand {
        let url = try XCTUnwrap(URL(string: raw))
        return try VocabularyURLCommandParser.parse(url, allowedSchemes: schemes).get()
    }

    private func assertFailure(
        _ raw: String,
        equals expected: VocabularyURLCommandError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url = URL(string: raw) else {
            XCTFail("Could not construct test URL", file: file, line: line)
            return
        }
        switch VocabularyURLCommandParser.parse(url, allowedSchemes: schemes) {
        case .success:
            XCTFail("Expected parsing to fail", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

final class VocabularyCommandServiceTests: XCTestCase {
    func testAddsAndCaseInsensitivelyDeduplicatesHotword() {
        var words = ["Existing"]
        let service = makeService(words: { words }, saveWords: { words = $0 })

        XCTAssertEqual(service.addHotword(" Ghostty "), .added)
        XCTAssertEqual(words, ["Existing", "Ghostty"])
        XCTAssertEqual(service.addHotword("gHoStTy"), .alreadyExists)
        XCTAssertEqual(words, ["Existing", "Ghostty"])
    }

    func testSnippetIsIdempotentAndRefusesConflict() {
        var snippets: [VocabularyCommandService.Snippet] = [("ghosty", "Ghostty")]
        let service = makeService(
            snippets: { snippets },
            saveSnippets: { snippets = $0 }
        )

        XCTAssertEqual(service.addSnippet(trigger: "GHOSTY", replacement: "Ghostty"), .alreadyExists)
        XCTAssertEqual(service.addSnippet(trigger: "ghosty", replacement: "Other"), .conflict)
        XCTAssertEqual(snippets.count, 1)
    }

    func testAddsSnippetAndSurfacesSaveFailure() {
        var snippets: [VocabularyCommandService.Snippet] = []
        let service = makeService(
            snippets: { snippets },
            saveSnippets: { snippets = $0 }
        )
        XCTAssertEqual(service.addSnippet(trigger: "ghosty", replacement: "Ghostty"), .added)
        XCTAssertEqual(snippets.map { [$0.trigger, $0.value] }, [["ghosty", "Ghostty"]])

        let failing = makeService(saveWords: { _ in throw TestError.failed })
        XCTAssertEqual(failing.addHotword("Ghostty"), .saveFailed)
    }

    func testRejectsInvalidInput() {
        let service = makeService()
        XCTAssertEqual(service.addHotword(" \n "), .invalidInput)
        XCTAssertEqual(service.addSnippet(trigger: "x\ny", replacement: "z"), .invalidInput)
    }

    private enum TestError: Error { case failed }

    private func makeService(
        words: @escaping () -> [String] = { [] },
        saveWords: @escaping ([String]) throws -> Void = { _ in },
        snippets: @escaping () -> [VocabularyCommandService.Snippet] = { [] },
        saveSnippets: @escaping ([VocabularyCommandService.Snippet]) throws -> Void = { _ in }
    ) -> VocabularyCommandService {
        VocabularyCommandService(
            loadHotwords: words,
            saveHotwords: saveWords,
            loadSnippets: snippets,
            saveSnippets: saveSnippets
        )
    }
}

final class VocabularyMacActionTests: XCTestCase {
    @MainActor
    func testColdStartNavigationWaitsForSettingsAndVocabularyConsumers() {
        let request = VocabularyNavigationRequest(section: .snippets, trigger: "wrong")
        let center = VocabularyNavigationCenter.shared
        center.submit(request)

        XCTAssertEqual(center.pendingRequest, request)
        XCTAssertTrue(center.hasPendingSettingsNavigation)

        center.consume(request)
        XCTAssertNil(center.pendingRequest)
        XCTAssertTrue(center.hasPendingSettingsNavigation)

        center.consumeSettingsNavigation()
        XCTAssertFalse(center.hasPendingSettingsNavigation)
    }

    func testRegistryAndPromptExposeVocabularyTools() {
        let names = Set(ActionRegistry.allActions.map(\.name))
        XCTAssertTrue(names.contains("open_vocabulary"))
        XCTAssertTrue(names.contains("prepare_snippet_from_selection"))
        XCTAssertTrue(names.contains("add_selected_hotword"))
        XCTAssertTrue(ProcessingMode.macActionPromptTemplate.contains("打开词典"))
        XCTAssertTrue(ProcessingMode.macActionPromptTemplate.contains("替换这个单词"))
        XCTAssertFalse(ProcessingMode.macActionPromptTemplate.contains("{selected}"))
    }

    func testMissingSelectionFailsWithoutClipboardFallback() async {
        let action = PrepareSnippetFromSelectionAction()
        let result = await action.execute(
            args: [:],
            context: MacActionContext(selectedText: "")
        )
        XCTAssertFalse(result.success)
    }

    func testNavigationRequestFocusRules() {
        XCTAssertEqual(
            VocabularyNavigationRequest(section: .hotwords).focus,
            .hotword
        )
        XCTAssertEqual(
            VocabularyNavigationRequest(section: .snippets, trigger: "wrong").focus,
            .snippetReplacement
        )
        XCTAssertNil(VocabularyNavigationRequest(section: .snippets).focus)
    }
}
