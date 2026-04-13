import XCTest
@testable import Type4Me

final class ModeStorageTests: XCTestCase {

    private let testURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("type4me-test-modes.json")

    override func tearDown() {
        try? FileManager.default.removeItem(at: testURL)
    }

    func testSaveAndLoad() throws {
        let storage = ModeStorage(fileURL: testURL)
        let modes = ProcessingMode.builtins + [
            ProcessingMode(id: UUID(), name: "Custom", prompt: "Do {text}", isBuiltin: false)
        ]
        try storage.save(modes)
        let loaded = storage.load()
        // built-in modes are auto-injected if missing
        XCTAssertTrue(loaded.contains { $0.name == "Custom" })
        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.direct.id })
    }

    func testLoadMissing_returnsBuiltins() {
        let storage = ModeStorage(fileURL: testURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded, ProcessingMode.defaults)
    }

    func testLoadMigratesLegacyBuiltinModesToDeletableModes() throws {
        let storage = ModeStorage(fileURL: testURL)
        let legacyModes = [
            ProcessingMode.direct,
            ProcessingMode(
                id: ProcessingMode.smartDirect.id,
                name: "智能模式",
                prompt: "",
                isBuiltin: true
            ),
            ProcessingMode(
                id: ProcessingMode.translateId,
                name: "英文翻译",
                prompt: "legacy",
                isBuiltin: true,
                processingLabel: "翻译中"
            ),
        ]

        try storage.save(legacyModes)
        let loaded = storage.load()

        let smart = loaded.first(where: { $0.id == ProcessingMode.smartDirect.id })
        let translate = loaded.first(where: { $0.id == ProcessingMode.translate.id })

        XCTAssertEqual(smart?.isBuiltin, false)
        XCTAssertEqual(smart?.prompt, ProcessingMode.smartDirect.prompt)
        XCTAssertEqual(translate?.isBuiltin, false)
        XCTAssertEqual(translate?.prompt, ProcessingMode.translate.prompt)
    }

    func testDeletedDefaultModesAreNotReinserted() throws {
        let storage = ModeStorage(fileURL: testURL)
        try storage.save([ProcessingMode.direct])

        let loaded = storage.load()

        // direct is kept
        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.direct.id })
        // smartDirect and translate were removed and not re-injected
        XCTAssertFalse(loaded.contains { $0.id == ProcessingMode.smartDirect.id })
        XCTAssertFalse(loaded.contains { $0.id == ProcessingMode.translate.id })
    }

    func testCustomSmartModePromptIsPreserved() throws {
        let storage = ModeStorage(fileURL: testURL)
        let customSmart = ProcessingMode(
            id: ProcessingMode.smartDirect.id,
            name: "智能模式",
            prompt: "自定义智能 Prompt: {text}",
            isBuiltin: false,
            processingLabel: "修正中"
        )

        try storage.save([ProcessingMode.direct, customSmart])
        let loaded = storage.load()

        XCTAssertEqual(loaded.first(where: { $0.id == ProcessingMode.smartDirect.id })?.prompt, customSmart.prompt)
        XCTAssertEqual(loaded.first(where: { $0.id == ProcessingMode.smartDirect.id })?.processingLabel, customSmart.processingLabel)
    }

    func testLoadMigratesLegacySeededDefaultPromptsWhenUnchanged() throws {
        let storage = ModeStorage(fileURL: testURL)
        var legacyFormalWriting = ProcessingMode.formalWriting
        legacyFormalWriting.prompt = ProcessingMode.legacyFormalWritingPromptTemplate
        legacyFormalWriting.processingLabel = "我的润色中"
        legacyFormalWriting.hotkeyCode = 30

        var legacyTranslate = ProcessingMode.translate
        legacyTranslate.prompt = ProcessingMode.legacyTranslatePromptTemplate
        legacyTranslate.processingLabel = "我的翻译中"
        legacyTranslate.hotkeyCode = 31

        try storage.save([ProcessingMode.direct, legacyFormalWriting, legacyTranslate])
        let loaded = storage.load()

        let formalWriting = loaded.first(where: { $0.id == ProcessingMode.formalWriting.id })
        let translate = loaded.first(where: { $0.id == ProcessingMode.translate.id })

        XCTAssertEqual(formalWriting?.prompt, ProcessingMode.formalWriting.prompt)
        XCTAssertEqual(formalWriting?.processingLabel, ProcessingMode.formalWriting.processingLabel)
        XCTAssertEqual(formalWriting?.hotkeyCode, 30)

        XCTAssertEqual(translate?.prompt, ProcessingMode.translate.prompt)
        XCTAssertEqual(translate?.processingLabel, "我的翻译中")
        XCTAssertEqual(translate?.hotkeyCode, 31)
    }

    func testCustomizedSeededDefaultPromptsArePreserved() throws {
        let storage = ModeStorage(fileURL: testURL)
        var customFormalWriting = ProcessingMode.formalWriting
        customFormalWriting.prompt = "请把文本整理成更正式的版本：\n{text}"

        var customTranslate = ProcessingMode.translate
        customTranslate.prompt = "Translate this into concise English:\n{text}"

        try storage.save([ProcessingMode.direct, customFormalWriting, customTranslate])
        let loaded = storage.load()

        XCTAssertEqual(
            loaded.first(where: { $0.id == ProcessingMode.formalWriting.id })?.prompt,
            customFormalWriting.prompt
        )
        XCTAssertEqual(
            loaded.first(where: { $0.id == ProcessingMode.translate.id })?.prompt,
            customTranslate.prompt
        )
    }

    // MARK: - Hotkey field tests

    func testHotkeyFieldsArePersisted() throws {
        let storage = ModeStorage(fileURL: testURL)
        var mode = ProcessingMode(
            id: UUID(), name: "Test", prompt: "{text}", isBuiltin: false
        )
        mode.hotkeyCode = 61
        mode.hotkeyModifiers = 0
        mode.hotkeyStyle = .hold

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Test" }

        XCTAssertEqual(loadedMode?.hotkeyCode, 61)
        XCTAssertEqual(loadedMode?.hotkeyModifiers, 0)
        XCTAssertEqual(loadedMode?.hotkeyStyle, .hold)
    }

    func testMissingHotkeyFieldsDefaultGracefully() throws {
        let storage = ModeStorage(fileURL: testURL)
        // Simulate old JSON without hotkey fields
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"快速模式","prompt":"","isBuiltin":true,"processingLabel":"处理中","isDualChannel":false}]
        """
        try json.data(using: .utf8)!.write(to: testURL)
        let loaded = storage.load()
        let direct = loaded.first { $0.id == ProcessingMode.direct.id }

        // Old JSON has no hotkey fields - should decode gracefully to today's builtin default.
        XCTAssertEqual(direct?.hotkeyStyle, ProcessingMode.direct.hotkeyStyle)
    }

    func testToggleStyleIsPersisted() throws {
        let storage = ModeStorage(fileURL: testURL)
        var mode = ProcessingMode(
            id: UUID(), name: "Toggle Mode", prompt: "{text}", isBuiltin: false
        )
        mode.hotkeyCode = 58
        mode.hotkeyStyle = .toggle

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Toggle Mode" }

        XCTAssertEqual(loadedMode?.hotkeyCode, 58)
        XCTAssertEqual(loadedMode?.hotkeyStyle, .toggle)
    }
}
