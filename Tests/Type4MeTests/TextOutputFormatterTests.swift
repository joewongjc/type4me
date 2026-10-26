import XCTest
@testable import Type4Me

final class TextOutputFormatterTests: XCTestCase {
    private func options(
        spacing: CJKSpacingMode = .pangu,
        cornerQuotes: Bool = false,
        trailing: TrailingPunctuationMode = .off
    ) -> TextOutputFormattingOptions {
        .init(
            cjkSpacingMode: spacing,
            usesCornerQuotes: cornerQuotes,
            trailingPunctuationMode: trailing
        )
    }

    func testSpacingModes() {
        XCTAssertEqual(
            TextOutputFormatter.format("第3个版本", options: options(spacing: .pangu)),
            "第 3 个版本"
        )
        XCTAssertEqual(
            TextOutputFormatter.format("第3个  版本", options: options(spacing: .off)),
            "第3个  版本"
        )
        XCTAssertEqual(
            TextOutputFormatter.format("我已经把最新的 prompt 提交，第 3 个", options: options(spacing: .remove)),
            "我已经把最新的prompt提交，第3个"
        )
    }

    func testPanguCoreCharacterRanges() {
        let cases: [(String, String)] = [
            ("中文abc", "中文 abc"),
            ("123中文", "123 中文"),
            ("中文Ø漢字", "中文 Ø 漢字"),
            ("我是α，我是Ω", "我是 α，我是 Ω"),
            ("中文Ⅶ漢字", "中文 Ⅶ 漢字"),
            ("abc⻤123", "abc ⻤ 123"),
            ("abc⾗123", "abc ⾗ 123"),
            ("abcあ123", "abc あ 123"),
            ("abcア123", "abc ア 123"),
            ("abcㄅ123", "abc ㄅ 123"),
            ("abc㈱123", "abc ㈱ 123"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TextOutputFormatter.format(input, options: options()), expected, input)
        }
    }

    func testPanguSymbolsQuotesAndBrackets() {
        let cases: [(String, String)] = [
            ("新八的構造成分有95%是眼鏡、3%是水、2%是垃圾", "新八的構造成分有 95% 是眼鏡、3% 是水、2% 是垃圾"),
            (#"前面"中文123漢字"後面"#, #"前面 "中文 123 漢字" 後面"#),
            ("前面(中文123漢字)後面", "前面 (中文 123 漢字) 後面"),
            ("前面/後面", "前面 / 後面"),
            ("得到一個A/B的結果", "得到一個 A/B 的結果"),
            ("前面-後面", "前面 - 後面"),
            ("氣溫是-5度左右", "氣溫是 -5 度左右"),
            ("參數要加-m的旗標", "參數要加 -m 的旗標"),
            ("前面#銀河公車指南", "前面 #銀河公車指南"),
            ("中文·English", "中文・English"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TextOutputFormatter.format(input, options: options()), expected, input)
        }
    }

    func testPanguProtectsTechnicalTokensAndPaths() {
        let cases: [(String, String)] = [
            ("Anthropic的claude-4-opus模型", "Anthropic 的 claude-4-opus 模型"),
            ("OpenAI的GPT-5模型", "OpenAI 的 GPT-5 模型"),
            ("在/home目錄", "在 /home 目錄"),
            ("查看/etc/passwd文件", "查看 /etc/passwd 文件"),
            ("檢查src/main.py文件", "檢查 src/main.py 文件"),
            ("參考./docs/API.md文件", "參考 ./docs/API.md 文件"),
            ("從結果來看，`a.getB()`返回值為null", "從結果來看，`a.getB()` 返回值為 null"),
            ("function(123)", "function(123)"),
            ("Math.floor(x)中文", "Math.floor(x) 中文"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TextOutputFormatter.format(input, options: options()), expected, input)
        }
    }

    func testPanguSpecialPlainTextBranches() {
        let cases: [(String, String)] = [
            ("前面|後面", "前面 | 後面"),
            ("條件是x|y的情況", "條件是 x|y 的情況"),
            ("你+我=我們", "你 + 我 = 我們"),
            ("得到一個A+B的結果", "得到一個 A+B 的結果"),
            ("我會寫C++的程式", "我會寫 C++ 的程式"),
            ("打+886這個號碼", "打 +886 這個號碼"),
            ("他说”你好”啊", "他说 ”你好” 啊"),
            ("檔案在C:\\Users\\name\\", "檔案在 C:\\Users\\name\\"),
            ("<p>一行文本</p>", "<p>一行文本</p>"),
            (#"<input value="測試123">"#, #"<input value="測試 123">"#),
            ("在這裡插入一個<div>標籤", "在這裡插入一個 <div> 標籤"),
            ("回傳Promise<string>就好", "回傳 Promise<string> 就好"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TextOutputFormatter.format(input, options: options()), expected, input)
        }
    }

    func testPanguPreservesNBSPAndIsIdempotent() {
        let input = "我們說We\u{00a0}invited\n第\u{00a0}5\u{00a0}章"
        let once = TextOutputFormatter.format(input, options: options())
        XCTAssertEqual(once, "我們說 We\u{00a0}invited\n第\u{00a0}5\u{00a0}章")
        XCTAssertEqual(TextOutputFormatter.format(once, options: options()), once)
    }

    func testCornerQuoteReplacementRunsBeforePanguSpacing() {
        XCTAssertEqual(
            TextOutputFormatter.format(
                "他说“你好”，她说‘再见’，然后说\"OK\"。",
                options: options(cornerQuotes: true)
            ),
            "他说「你好」，她说『再见』，然后说 \"OK\"。"
        )
        XCTAssertEqual(
            TextOutputFormatter.format("“未配对‘", options: options(spacing: .off, cornerQuotes: true)),
            "「未配对『"
        )
        XCTAssertEqual(
            TextOutputFormatter.format("他说“你好”", options: options(spacing: .off)),
            "他说“你好”"
        )
    }

    func testCornerQuotesPreserveEnglishApostrophes() {
        // User report scenario: translation output with curly apostrophes
        let translationSentence = "Sorry, I was just driving outside. If there’s anything we need to discuss in detail, I’m available now."
        XCTAssertEqual(
            TextOutputFormatter.format(translationSentence, options: options(spacing: .pangu, cornerQuotes: true)),
            "Sorry, I was just driving outside. If there’s anything we need to discuss in detail, I’m available now."
        )

        // Contractions & possessives
        let contractions = "Don’t worry, it’s not Apple’s fault, we’ll fix it by 5 o’clock."
        XCTAssertEqual(
            TextOutputFormatter.format(contractions, options: options(spacing: .pangu, cornerQuotes: true)),
            "Don’t worry, it’s not Apple’s fault, we’ll fix it by 5 o’clock."
        )

        // Plural possessive & leading decade/omissions
        let edgeCases = "The users’ data from ’90s rock ’n’ roll was restored."
        XCTAssertEqual(
            TextOutputFormatter.format(edgeCases, options: options(spacing: .pangu, cornerQuotes: true)),
            "The users’ data from ’90s rock ’n’ roll was restored."
        )

        // Mixed Chinese quotes and English contractions
        let mixed = "他说“I’m ready”，但大家觉得“it’s impossible”，她说‘没关系’。"
        XCTAssertEqual(
            TextOutputFormatter.format(mixed, options: options(spacing: .pangu, cornerQuotes: true)),
            "他说「I’m ready」，但大家觉得「it’s impossible」，她说『没关系』。"
        )

        // Nested quote wrapping English words
        let quotedEnglish = "关于‘Prompt Engineering’的研究"
        XCTAssertEqual(
            TextOutputFormatter.format(quotedEnglish, options: options(spacing: .pangu, cornerQuotes: true)),
            "关于『Prompt Engineering』的研究"
        )
    }

    func testTrailingPunctuationRunsLast() {
        XCTAssertEqual(
            TextOutputFormatter.format("版本3。", options: options(trailing: .period)),
            "版本 3"
        )
        XCTAssertEqual(
            TextOutputFormatter.format("版本3！", options: options(trailing: .all)),
            "版本 3"
        )
    }

    func testPerModePunctuationStrategiesCoverCJKAndASCII() {
        let input = "你好，world. 真的？Yes, really! 太棒了！"

        XCTAssertEqual(
            TextOutputFormatter.format(
                input,
                options: .init(
                    cjkSpacingMode: .off,
                    usesCornerQuotes: false,
                    punctuationMode: .preserve
                )
            ),
            input
        )
        XCTAssertEqual(
            TextOutputFormatter.format(
                "真的吗？当然可以……",
                options: .init(
                    cjkSpacingMode: .off,
                    usesCornerQuotes: false,
                    punctuationMode: .stripTrailing
                )
            ),
            "真的吗？当然可以"
        )
        XCTAssertEqual(
            TextOutputFormatter.format(
                input,
                options: .init(
                    cjkSpacingMode: .off,
                    usesCornerQuotes: false,
                    punctuationMode: .questionsAndExclamationsOnly
                )
            ),
            "你好world 真的？Yes really! 太棒了！"
        )
        XCTAssertEqual(
            TextOutputFormatter.format(
                "第一项：Codex CLI——完成！\n第二项：继续？🚀",
                options: .init(
                    cjkSpacingMode: .off,
                    usesCornerQuotes: false,
                    punctuationMode: .removeAll
                )
            ),
            "第一项Codex CLI完成\n第二项继续🚀"
        )
    }

    func testPerModePunctuationRunsAfterQuotesAndSpacingAndIsIdempotent() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: true,
            punctuationMode: .questionsAndExclamationsOnly
        )
        let once = TextOutputFormatter.format("他说“版本3”，真的吗？！", options: options)

        XCTAssertEqual(once, "他说版本 3 真的吗？！")
        XCTAssertEqual(TextOutputFormatter.format(once, options: options), once)
    }

    func testModePunctuationOverrideResolvesAgainstLegacyGlobalSetting() throws {
        let suite = "TextOutputFormatterTests.Punctuation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CJKSpacingMode.off.rawValue, forKey: CJKSpacingMode.storageKey)
        defaults.set("period", forKey: "tf_stripTrailingPunctuation")

        XCTAssertEqual(
            TextOutputFormatter.format(
                "你好！。",
                options: .current(userDefaults: defaults, modePunctuation: .inherit)
            ),
            "你好！"
        )
        XCTAssertEqual(
            TextOutputFormatter.format(
                "你好！。",
                options: .current(userDefaults: defaults, modePunctuation: .preserve)
            ),
            "你好！。"
        )
        XCTAssertEqual(
            TextOutputFormatter.format(
                "你好！。",
                options: .current(userDefaults: defaults, modePunctuation: .stripTrailing)
            ),
            "你好"
        )
    }

    func testSpacingPreferenceMigration() throws {
        let suite = "TextOutputFormatterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CJKSpacingMode.current(userDefaults: defaults), .pangu)
        CJKSpacingMode.migrateIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CJKSpacingMode.storageKey), CJKSpacingMode.pangu.rawValue)

        defaults.removeObject(forKey: CJKSpacingMode.storageKey)
        defaults.set(false, forKey: CJKSpacingMode.legacyStorageKey)
        CJKSpacingMode.migrateIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CJKSpacingMode.storageKey), CJKSpacingMode.remove.rawValue)

        defaults.removeObject(forKey: CJKSpacingMode.storageKey)
        defaults.set(true, forKey: CJKSpacingMode.legacyStorageKey)
        CJKSpacingMode.migrateIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CJKSpacingMode.storageKey), CJKSpacingMode.pangu.rawValue)

        defaults.set(CJKSpacingMode.off.rawValue, forKey: CJKSpacingMode.storageKey)
        defaults.set(true, forKey: CJKSpacingMode.legacyStorageKey)
        CJKSpacingMode.migrateIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CJKSpacingMode.storageKey), CJKSpacingMode.off.rawValue)
    }
}
