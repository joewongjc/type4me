import XCTest
@testable import Type4Me

final class ModeStorageTests: XCTestCase {

    private let testURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("type4me-test-modes.json")

    override func tearDown() {
        try? FileManager.default.removeItem(at: testURL)
    }

    func testManualInputHotkeysSurviveCanonicalModeReload() throws {
        let suite = "ModeStorageTests.ManualInput.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        var modes = ProcessingMode.builtins + [ProcessingMode.translate]
        for index in modes.indices where modes[index].supportsManualInput {
            modes[index].manualInputHotkey = HotkeyBinding(keyCode: 40 + index, modifiers: 0, style: .toggle)
        }
        try storage.save(modes)
        let loaded = storage.load()
        for mode in modes where mode.supportsManualInput {
            XCTAssertEqual(loaded.first { $0.id == mode.id }?.manualInputHotkey,
                           mode.manualInputHotkey, mode.name)
            XCTAssertEqual(loaded.first { $0.id == mode.id }?.hotkeyBindings,
                           mode.hotkeyBindings, "Voice bindings must remain independent")
        }
    }

    func testLegacyModeDoesNotAcquireManualInputHotkey() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","prompt":"Translate {text}","isBuiltin":false,"hotkeyCode":18,"hotkeyModifiers":524288}
        """
        let mode = try JSONDecoder().decode(ProcessingMode.self, from: Data(json.utf8))
        XCTAssertNil(mode.manualInputHotkey)
        XCTAssertEqual(mode.hotkeyBindings.count, 1)
        XCTAssertTrue(mode.supportsManualInput)
        XCTAssertFalse(ProcessingMode.direct.supportsManualInput)
        XCTAssertTrue(ProcessingMode.translation().supportsManualInput)
    }

    func testSaveAndLoad() throws {
        let storage = ModeStorage(fileURL: testURL)
        let modes = ProcessingMode.builtins + [
            ProcessingMode(
                id: UUID(),
                name: "Custom",
                description: "A concise homepage summary",
                prompt: "Do {text}",
                isBuiltin: false
            )
        ]
        try storage.save(modes)
        let loaded = storage.load()
        // built-in modes are auto-injected if missing
        XCTAssertTrue(loaded.contains { $0.name == "Custom" })
        XCTAssertEqual(
            loaded.first(where: { $0.name == "Custom" })?.description,
            "A concise homepage summary"
        )
        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.direct.id })

        let savedJSON = try String(contentsOf: testURL, encoding: .utf8)
        XCTAssertTrue(savedJSON.contains("\"description\""))
    }

    func testMissingAndUnknownPunctuationModesDefaultToInherit() throws {
        let id = UUID()
        let missing = """
        {"id":"\(id.uuidString)","name":"Legacy","prompt":"Do {text}","isBuiltin":false,"processingLabel":"处理中"}
        """
        let unknown = """
        {"id":"\(id.uuidString)","name":"Future","prompt":"Do {text}","isBuiltin":false,"processingLabel":"处理中","punctuationMode":"future-mode"}
        """

        XCTAssertEqual(
            try JSONDecoder().decode(ProcessingMode.self, from: Data(missing.utf8)).punctuationMode,
            .inherit
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ProcessingMode.self, from: Data(unknown.utf8)).punctuationMode,
            .inherit
        )
    }

    func testPunctuationModePersistsAcrossBuiltinMigrationsAndCustomModes() throws {
        let suite = "ModeStorageTests.Punctuation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tf_agentModeSeeded")
        defaults.set(true, forKey: "tf_shortTextExemptionMigrated")

        let styles: [ModePunctuationMode] = [
            .preserve,
            .stripTrailing,
            .questionsAndExclamationsOnly,
            .removeAll,
            .preserve,
            .stripTrailing,
            .questionsAndExclamationsOnly,
        ]
        var modes = ProcessingMode.builtins
        for index in modes.indices {
            modes[index].punctuationMode = styles[index]
        }
        let custom = ProcessingMode(
            id: UUID(),
            name: "Casual",
            prompt: "Do {text}",
            isBuiltin: false,
            punctuationMode: .removeAll
        )
        modes.append(custom)

        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        try storage.save(modes)
        let loaded = storage.load()

        for (index, mode) in modes.dropLast().enumerated() {
            XCTAssertEqual(
                loaded.first(where: { $0.id == mode.id })?.punctuationMode,
                styles[index],
                mode.name
            )
        }
        XCTAssertEqual(loaded.first(where: { $0.id == custom.id })?.punctuationMode, .removeAll)
    }

    func testHandleItLoadsAsBuiltinKeepingUserEdits() throws {
        let suite = "ModeStorageTests.HandleIt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tf_agentModeSeeded")
        defaults.set(true, forKey: "tf_shortTextExemptionMigrated")

        // Saved while Handle It was still a deletable default.
        var stored = ProcessingMode.agentMode
        stored.isBuiltin = false
        stored.prompt = "Just do it: {text}"
        stored.hotkeyBindings = [HotkeyBinding(keyCode: 40, modifiers: 0, style: .hold)]
        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        try storage.save(ProcessingMode.builtins.filter { $0.id != ProcessingMode.agentModeId } + [stored])

        let loaded = try XCTUnwrap(storage.load().first { $0.id == ProcessingMode.agentModeId })
        XCTAssertTrue(loaded.isBuiltin)
        XCTAssertEqual(loaded.prompt, stored.prompt)
        XCTAssertEqual(loaded.hotkeyBindings, stored.hotkeyBindings)
    }

    func testDeletedHandleItComesBackAsBuiltin() throws {
        let suite = "ModeStorageTests.HandleItMissing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tf_agentModeSeeded")
        defaults.set(true, forKey: "tf_shortTextExemptionMigrated")
        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        try storage.save(ProcessingMode.builtins.filter { $0.id != ProcessingMode.agentModeId })

        let loaded = storage.load()
        XCTAssertEqual(loaded.last?.id, ProcessingMode.agentModeId)
        XCTAssertTrue(loaded.last?.isBuiltin ?? false)
    }

    func testOutputFormattingCapabilityMatchesModeBehavior() {
        XCTAssertTrue(ProcessingMode.direct.supportsOutputFormatting)
        XCTAssertTrue(ProcessingMode.intelliSense.supportsOutputFormatting)
        XCTAssertTrue(ProcessingMode.translation().supportsOutputFormatting)
        XCTAssertTrue(ProcessingMode.formalWriting.supportsOutputFormatting)
        XCTAssertTrue(ProcessingMode.agentMode.supportsOutputFormatting)
        XCTAssertFalse(ProcessingMode.selectionAsk.supportsOutputFormatting)
        XCTAssertFalse(ProcessingMode.macAction.supportsOutputFormatting)
    }

    func testReorderedModesKeepExactOrderAcrossRestartLoad() throws {
        let preferenceKeys = [
            "tf_translateToChineseModeSeeded",
            "tf_agentModeSeeded",
            "tf_shortTextExemptionMigrated",
        ]
        let previousValues = Dictionary(uniqueKeysWithValues: preferenceKeys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        })
        defer {
            for key in preferenceKeys {
                if let value = previousValues[key] as? Any {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        preferenceKeys.forEach { UserDefaults.standard.set(true, forKey: $0) }

        let storage = ModeStorage(fileURL: testURL)
        let reordered = Array(ProcessingMode.defaults.reversed())

        try storage.save(reordered)
        let loadedAfterRestart = storage.load()

        XCTAssertEqual(loadedAfterRestart.map(\.id), reordered.map(\.id))
    }

    func testNewDefaultHotkeysDoNotOverwriteExistingUserBindingsOrOrder() throws {
        let suite = "ModeStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tf_agentModeSeeded")
        defaults.set(true, forKey: "tf_shortTextExemptionMigrated")

        var existing = [
            ProcessingMode.selectionAsk,
            ProcessingMode.translation(target: .japanese),
            ProcessingMode.direct,
            ProcessingMode.formalWriting,
            ProcessingMode.macAction,
            ProcessingMode.intelliSense,
            ProcessingMode.promptOptimize,
            ProcessingMode.agentMode,
        ]
        for index in existing.indices {
            existing[index].hotkeyBindings = [
                HotkeyBinding(
                    keyCode: 70 + index,
                    modifiers: UInt64(index),
                    style: index.isMultiple(of: 2) ? .hold : .toggle
                ),
            ]
        }
        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        try storage.save(existing)

        let loaded = storage.load()

        XCTAssertEqual(loaded.map(\.id), existing.map(\.id))
        for mode in existing {
            XCTAssertEqual(
                loaded.first { $0.id == mode.id }?.hotkeyBindings,
                mode.hotkeyBindings
            )
        }
    }

    func testLoadMissing_returnsBuiltins() {
        let storage = ModeStorage(fileURL: testURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded, ProcessingMode.defaults)
    }

    func testFreshDefaultsUseProductModeOrder() {
        let ids = ProcessingMode.defaults.map(\.id)

        XCTAssertEqual(ids, [
            ProcessingMode.directId,
            ProcessingMode.intelliSenseId,
            ProcessingMode.translationModeId,
            ProcessingMode.selectionAskId,
            ProcessingMode.macActionId,
            ProcessingMode.formalWritingId,
            ProcessingMode.promptOptimizeId,
            ProcessingMode.agentModeId,
        ])
        XCTAssertTrue(ProcessingMode.intelliSense.isBuiltin)
    }

    func testExistingInstallAppendsIntelliSenseWithoutReorderingModes() throws {
        let storage = ModeStorage(fileURL: testURL)
        let custom = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "{text}",
            isBuiltin: false
        )
        let existing = ProcessingMode.builtins.filter {
            $0.id != ProcessingMode.intelliSenseId
        } + [custom]
        try storage.save(existing)

        let loaded = storage.load()
        let originalIDs = existing.map(\.id)

        XCTAssertEqual(Array(loaded.prefix(originalIDs.count)).map(\.id), originalIDs)
        XCTAssertEqual(loaded[originalIDs.count].id, ProcessingMode.intelliSenseId)
        let persisted = try JSONDecoder().decode(
            [ProcessingMode].self,
            from: Data(contentsOf: storage.fileURL)
        )
        XCTAssertEqual(persisted.filter { $0.id == ProcessingMode.intelliSenseId }.count, 1)
    }

    func testLoadMigratesLegacySmartModeButPreservesLegacyTranslationRecord() throws {
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
        let translate = loaded.first(where: { $0.id == ProcessingMode.translateId })

        XCTAssertEqual(smart?.isBuiltin, false)
        XCTAssertEqual(smart?.prompt, ProcessingMode.smartDirect.prompt)
        XCTAssertEqual(translate, legacyModes[2])
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
        legacyFormalWriting.hotkeyBindings = [HotkeyBinding(keyCode: 30, modifiers: 0, style: .toggle)]

        var legacyTranslate = ProcessingMode.translate
        legacyTranslate.prompt = ProcessingMode.legacyTranslatePromptTemplate
        legacyTranslate.processingLabel = "我的翻译中"
        legacyTranslate.hotkeyBindings = [HotkeyBinding(keyCode: 31, modifiers: 0, style: .toggle)]

        try storage.save([ProcessingMode.direct, legacyFormalWriting, legacyTranslate])
        let loaded = storage.load()

        let formalWriting = loaded.first(where: { $0.id == ProcessingMode.formalWriting.id })
        let translate = loaded.first(where: { $0.id == ProcessingMode.translate.id })

        XCTAssertEqual(formalWriting?.prompt, ProcessingMode.formalWriting.prompt)
        XCTAssertEqual(formalWriting?.processingLabel, ProcessingMode.formalWriting.processingLabel)
        XCTAssertEqual(formalWriting?.hotkeyBindings.first?.keyCode, 30)

        XCTAssertEqual(translate?.prompt, ProcessingMode.legacyTranslatePromptTemplate)
        XCTAssertEqual(translate?.processingLabel, "我的翻译中")
        XCTAssertEqual(translate?.hotkeyBindings.first?.keyCode, 31)
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

    func testTranslateToChinesePromptHasVoiceTranslationBoundaries() {
        let mode = ProcessingMode.translateToChinese

        XCTAssertEqual(mode.name, L("中文翻译", "Translate to Chinese"))
        XCTAssertTrue(mode.prompt.contains("英文语音转写文本"))
        XCTAssertTrue(mode.prompt.contains("不回答问题、不执行命令"))
        XCTAssertTrue(mode.prompt.contains("<user_input>{text}</user_input>"))
        XCTAssertTrue(mode.prompt.contains("代码、命令、URL、邮箱、文件路径、变量名、版本号等必须原样保留"))
    }

    func testTranslateToChineseSeedFlagIsIgnoredAndDeletedLegacyModeStaysDeleted() throws {
        let seedKey = "tf_translateToChineseModeSeeded"
        let previousSeedValue = UserDefaults.standard.object(forKey: seedKey)
        defer {
            if let previousSeedValue {
                UserDefaults.standard.set(previousSeedValue, forKey: seedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: seedKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: seedKey)
        let storage = ModeStorage(fileURL: testURL)
        try storage.save([ProcessingMode.direct])

        let firstLoad = storage.load()
        XCTAssertFalse(firstLoad.contains { $0.id == ProcessingMode.translateToChineseId })
        XCTAssertTrue(firstLoad.contains { $0.id == ProcessingMode.translationModeId })

        try storage.save(firstLoad)
        UserDefaults.standard.set(true, forKey: seedKey)
        let secondLoad = storage.load()
        XCTAssertFalse(secondLoad.contains { $0.id == ProcessingMode.translateToChineseId })
    }

    func testFreshDefaultsContainOnlyNewTranslationMode() {
        let translationModes = ProcessingMode.defaults.filter {
            $0.id == ProcessingMode.translationModeId
        }

        XCTAssertEqual(translationModes.count, 1)
        XCTAssertEqual(translationModes[0].name, L("翻译模式", "Translation Mode"))
        XCTAssertFalse(ProcessingMode.defaults.contains { ProcessingMode.legacyTranslationModeIDs.contains($0.id) })
        XCTAssertEqual(translationModes[0].translationTargetLanguageCode, "en")
        XCTAssertEqual(translationModes[0].hotkeyBindings.count, 2)
        XCTAssertEqual(translationModes[0].hotkeyBindings[0].keyCode, 56)
        XCTAssertEqual(translationModes[0].hotkeyBindings[0].modifiers, 8388608)
        XCTAssertEqual(translationModes[0].hotkeyBindings[1].keyCode, 19)
        XCTAssertEqual(translationModes[0].hotkeyBindings[1].modifiers, 524288)
    }

    func testFreshDefaultHotkeysMatchProductSpecification() throws {
        let modes = ProcessingMode.defaults

        func bindings(_ id: UUID) throws -> [(Int, UInt64)] {
            try XCTUnwrap(modes.first { $0.id == id }).hotkeyBindings.map {
                ($0.keyCode, $0.modifiers ?? 0)
            }
        }

        XCTAssertEqual(try bindings(ProcessingMode.directId).map(\.0), [63])
        XCTAssertEqual(try bindings(ProcessingMode.directId).map(\.1), [0])
        XCTAssertEqual(try bindings(ProcessingMode.intelliSenseId).map(\.0), [59, 18])
        XCTAssertEqual(try bindings(ProcessingMode.intelliSenseId).map(\.1), [8388608, 524288])
        XCTAssertEqual(try bindings(ProcessingMode.translationModeId).map(\.0), [56, 19])
        XCTAssertEqual(try bindings(ProcessingMode.translationModeId).map(\.1), [8388608, 524288])
        XCTAssertEqual(try bindings(ProcessingMode.selectionAskId).map(\.0), [49, 20])
        XCTAssertEqual(try bindings(ProcessingMode.selectionAskId).map(\.1), [8388608, 524288])
        XCTAssertEqual(try bindings(ProcessingMode.macActionId).map(\.0), [21])
        XCTAssertEqual(try bindings(ProcessingMode.macActionId).map(\.1), [524288])
        XCTAssertEqual(try bindings(ProcessingMode.formalWritingId).map(\.0), [23])
        XCTAssertEqual(try bindings(ProcessingMode.formalWritingId).map(\.1), [524288])
        XCTAssertTrue(try bindings(ProcessingMode.promptOptimizeId).isEmpty)
        XCTAssertTrue(try bindings(ProcessingMode.agentModeId).isEmpty)
    }

    func testRemovedLegacyAndSupersededModesAreNotFreshDefaults() {
        let ids = Set(ProcessingMode.defaults.map(\.id))

        XCTAssertFalse(ids.contains(ProcessingMode.translateId))
        XCTAssertFalse(ids.contains(ProcessingMode.translateToChineseId))
        XCTAssertFalse(ids.contains(ProcessingMode.translate.id))
        XCTAssertFalse(ProcessingMode.defaults.contains { $0.name == ProcessingMode.commandMode.name })
    }

    func testExistingLegacyTranslationRecordsArePreservedAndNewModeAppended() throws {
        let suite = "ModeStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tf_agentModeSeeded")
        defaults.set(true, forKey: "tf_shortTextExemptionMigrated")

        var english = ProcessingMode.translate
        english.name = "My English Workflow"
        english.prompt = "My private prompt: {text}"
        english.description = "My description"
        english.processingLabel = "Working"
        english.hotkeyBindings = [
            HotkeyBinding(keyCode: 20, modifiers: 524288, style: .hold),
            HotkeyBinding(keyCode: 21, modifiers: 0, style: .toggle),
        ]
        english.shortTextExemption = 7
        var chinese = ProcessingMode.translateToChinese
        chinese.prompt = "My Chinese prompt: {text}"
        let original = [ProcessingMode.direct, english, chinese]
        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        try storage.save(original)

        let loaded = storage.load()

        XCTAssertEqual(loaded.first { $0.id == english.id }, english)
        XCTAssertEqual(loaded.first { $0.id == chinese.id }, chinese)
        XCTAssertLessThan(
            try XCTUnwrap(loaded.firstIndex { $0.id == english.id }),
            try XCTUnwrap(loaded.firstIndex { $0.id == chinese.id })
        )
        let translation = loaded.first { $0.id == ProcessingMode.translationModeId }
        XCTAssertEqual(translation?.translationTargetLanguageCode, "en")
        XCTAssertTrue(translation?.hotkeyBindings.isEmpty == true)
        XCTAssertEqual(loaded.filter { $0.id == ProcessingMode.translationModeId }.count, 1)
        XCTAssertEqual(storage.load(), loaded)
    }

    func testExistingUserTargetUsesLastSelectedLegacyChineseMode() throws {
        let suite = "ModeStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProcessingMode.translateToChineseId.uuidString, forKey: ModeSelectionPreference.storageKey)
        defaults.set(true, forKey: "tf_agentModeSeeded")
        defaults.set(true, forKey: "tf_shortTextExemptionMigrated")
        let storage = ModeStorage(fileURL: testURL, userDefaults: defaults)
        try storage.save([ProcessingMode.direct, ProcessingMode.translateToChinese])

        let loaded = storage.load()

        XCTAssertEqual(
            loaded.first { $0.id == ProcessingMode.translationModeId }?.translationTargetLanguageCode,
            "zh-Hans"
        )
    }

    func testNewTranslationCanonicalizationPreservesBindingsAndUnknownTarget() throws {
        let storage = ModeStorage(fileURL: testURL)
        let bindings = [HotkeyBinding(keyCode: 42, modifiers: 123, style: .hold)]
        var stored = ProcessingMode.translation(target: .japanese, hotkeyBindings: bindings)
        stored.name = "Tampered system name"
        stored.prompt = "Tampered prompt"
        stored.translationTargetLanguageCode = "x-future-language"
        try storage.save([ProcessingMode.direct, stored])

        let loaded = storage.load().first { $0.id == ProcessingMode.translationModeId }

        XCTAssertEqual(loaded?.name, ProcessingMode.translation().name)
        XCTAssertEqual(loaded?.prompt, TranslationPromptBuilder.baseTemplate)
        XCTAssertEqual(loaded?.hotkeyBindings, bindings)
        XCTAssertEqual(loaded?.translationTargetLanguageCode, "x-future-language")
        XCTAssertEqual(loaded?.shortTextExemption, 0)
    }

    // MARK: - Hotkey binding tests

    func testHotkeyBindingsArePersisted() throws {
        let storage = ModeStorage(fileURL: testURL)
        var mode = ProcessingMode(
            id: UUID(), name: "Test", prompt: "{text}", isBuiltin: false
        )
        mode.hotkeyBindings = [HotkeyBinding(keyCode: 61, modifiers: 0, style: .hold)]

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Test" }

        XCTAssertEqual(loadedMode?.hotkeyBindings.count, 1)
        XCTAssertEqual(loadedMode?.hotkeyBindings.first?.keyCode, 61)
        XCTAssertEqual(loadedMode?.hotkeyBindings.first?.modifiers, 0)
        XCTAssertEqual(loadedMode?.hotkeyBindings.first?.style, .hold)
    }

    func testMultipleMixedStyleBindingsRoundTrip() throws {
        let storage = ModeStorage(fileURL: testURL)
        let bindings = [
            HotkeyBinding(keyCode: 61, modifiers: 0, style: .hold),
            HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle),
            HotkeyBinding(keyCode: ModeBinding.mouseKeyCode(for: 2), modifiers: 0, style: .toggle),
        ]
        var mode = ProcessingMode(
            id: UUID(), name: "Multi", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: bindings
        )
        mode.name = "Multi"

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Multi" }

        XCTAssertEqual(loadedMode?.hotkeyBindings, bindings)
    }

    func testEmptyBindingsRoundTrip() throws {
        let storage = ModeStorage(fileURL: testURL)
        let mode = ProcessingMode(
            id: UUID(), name: "NoKeys", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: []
        )

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "NoKeys" }

        XCTAssertNotNil(loadedMode)
        XCTAssertTrue(loadedMode?.hotkeyBindings.isEmpty ?? false)
    }

    func testLegacySingleHotkeyFieldsMigrateToBinding() throws {
        let customId = UUID()
        // Old on-disk format used flat hotkeyCode/hotkeyModifiers/hotkeyStyle fields.
        let json = """
        [
          {"id":"\(customId.uuidString)","name":"Legacy","prompt":"Do {text}","isBuiltin":false,"processingLabel":"处理中","hotkeyCode":58,"hotkeyModifiers":524288,"hotkeyStyle":"hold"}
        ]
        """
        try json.data(using: .utf8)!.write(to: testURL)

        let loaded = ModeStorage(fileURL: testURL).load()
        let migrated = loaded.first { $0.id == customId }

        XCTAssertEqual(migrated?.hotkeyBindings.count, 1)
        XCTAssertEqual(migrated?.hotkeyBindings.first?.keyCode, 58)
        XCTAssertEqual(migrated?.hotkeyBindings.first?.modifiers, 524288)
        XCTAssertEqual(migrated?.hotkeyBindings.first?.style, .hold)
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

        // Old JSON has no hotkey fields - should decode gracefully to an empty binding list.
        XCTAssertNotNil(direct)
        XCTAssertTrue(direct?.hotkeyBindings.isEmpty ?? false)
    }

    func testMissingDescriptionMigratesOfficialModesAndKeepsCustomModesBlank() throws {
        let customId = UUID()
        let json = """
        [
          {"id":"00000000-0000-0000-0000-000000000001","name":"快速模式","prompt":"","isBuiltin":true,"processingLabel":"处理中"},
          {"id":"\(customId.uuidString)","name":"Legacy Custom","prompt":"Do {text}","isBuiltin":false,"processingLabel":"处理中"}
        ]
        """
        try json.data(using: .utf8)!.write(to: testURL)

        let loaded = ModeStorage(fileURL: testURL).load()

        XCTAssertEqual(
            loaded.first(where: { $0.id == ProcessingMode.direct.id })?.description,
            ProcessingMode.direct.description
        )
        XCTAssertEqual(
            loaded.first(where: { $0.id == customId })?.description,
            ""
        )
    }

    func testMissingExecutionKindDefaultsToRecording() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"旧模式","prompt":"Do {text}","isBuiltin":false,"processingLabel":"处理中"}
        """
        let mode = try JSONDecoder().decode(ProcessingMode.self, from: Data(json.utf8))
        XCTAssertEqual(mode.executionKind, .recording)
    }

    func testExistingUsersGetSelectionAskBuiltin() throws {
        let storage = ModeStorage(fileURL: testURL)
        try storage.save([ProcessingMode.direct, ProcessingMode.formalWriting])

        let loaded = storage.load()

        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.selectionAskId })
        XCTAssertEqual(
            loaded.first(where: { $0.id == ProcessingMode.selectionAskId })?.executionKind,
            .selectionAsk
        )
    }

    func testSelectionAskLegacyPromptMigratesToLatestPrompt() throws {
        let storage = ModeStorage(fileURL: testURL)
        var legacy = ProcessingMode.selectionAsk
        legacy.prompt = """
        你是 Type4Me 的划词问答助手。用户选中了一段文本，并固定询问：“这句话是什么意思？”

        请用中文回答，允许使用 Markdown，让排版清晰、易读。

        # 回答要求
        1. 先直接解释选中文本的核心含义。

        # 选中文本
        {selected}
        """

        try storage.save([ProcessingMode.direct, legacy])
        let loaded = storage.load()
        let migrated = loaded.first { $0.id == ProcessingMode.selectionAskId }

        XCTAssertEqual(migrated?.prompt, ProcessingMode.selectionAsk.prompt)
        XCTAssertTrue(migrated?.prompt.contains("# 用户语音问题") == true)
    }

    func testSelectionAskPreviousBuiltinPromptMigratesForConversationContext() throws {
        let storage = ModeStorage(fileURL: testURL)
        var previousBuiltin = ProcessingMode.selectionAsk
        previousBuiltin.prompt = """
        你是语音问答助手。用户可能选中了一段文本，也可能只通过语音提出一个问题或指令。

        # 回答要求
        1. 用户语音问题是最高优先级。必须严格执行用户语音问题，不要擅自改成解释、分析或模板。

        # 选中文本
        ```text
        {selected}
        ```

        # 用户语音问题
        ```text
        {text}
        ```
        """

        try storage.save([ProcessingMode.direct, previousBuiltin])
        let loaded = storage.load()
        let migrated = loaded.first { $0.id == ProcessingMode.selectionAskId }

        XCTAssertEqual(migrated?.prompt, ProcessingMode.selectionAsk.prompt)
        XCTAssertTrue(migrated?.prompt.contains("{conversation}") == true)
    }

    func testSelectionAskCustomPromptIsPreserved() throws {
        let storage = ModeStorage(fileURL: testURL)
        var custom = ProcessingMode.selectionAsk
        custom.prompt = "Custom ask prompt with {selected} and {text}"

        try storage.save([ProcessingMode.direct, custom])
        let loaded = storage.load()

        XCTAssertEqual(loaded.first { $0.id == ProcessingMode.selectionAskId }?.prompt, custom.prompt)
    }

    func testToggleStyleIsPersisted() throws {
        let storage = ModeStorage(fileURL: testURL)
        var mode = ProcessingMode(
            id: UUID(), name: "Toggle Mode", prompt: "{text}", isBuiltin: false
        )
        mode.hotkeyBindings = [HotkeyBinding(keyCode: 58, modifiers: 0, style: .toggle)]

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Toggle Mode" }

        XCTAssertEqual(loadedMode?.hotkeyBindings.first?.keyCode, 58)
        XCTAssertEqual(loadedMode?.hotkeyBindings.first?.style, .toggle)
    }
}
