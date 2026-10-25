import XCTest
@testable import Type4MeTransferCore

final class Type4MeTransferTests: XCTestCase {
    private let sample = Type4MeTransferPayload(
        asr: .init(provider: "volcano", fields: [
            "authMode": "apiKey",
            "apiKey": "0f3a9c6e-1b2d-4e5f-8a7b-9c0d1e2f3a4b",
            "resourceId": "volc.seedasr.sauc.duration",
        ]),
        llm: .init(provider: "deepseek", fields: [
            "apiKey": "sk-1234567890abcdef1234567890abcdef",
            "model": "deepseek-v4-flash",
            "baseURL": "https://api.deepseek.com",
            "_thinkingOff": "thinking",
        ]),
        sourceName: "MacBook Pro",
        createdAt: 1_792_800_000
    )

    func testTextRoundTrip() throws {
        let text = try Type4MeTransferCodec.encodeText(sample)
        XCTAssertTrue(text.hasPrefix(Type4MeTransferCodec.compressedPrefix))
        XCTAssertEqual(try Type4MeTransferCodec.decode(text), sample)
    }

    func testURLRoundTrip() throws {
        let url = try Type4MeTransferCodec.encodeURL(sample)
        XCTAssertTrue(url.hasPrefix("type4me://import?c=T4M2."))
        XCTAssertNotNil(URL(string: url))
        XCTAssertEqual(try Type4MeTransferCodec.decode(url), sample)
    }

    /// Two endpoints have to fit a QR code the iPhone camera reads at a glance
    /// and survive a chat message without being cut.
    func testTypicalPayloadStaysShort() throws {
        let url = try Type4MeTransferCodec.encodeURL(sample)
        XCTAssertLessThan(url.count, 600)
    }

    func testDecodesTextEmbeddedInLongerPasteWithLineBreaks() throws {
        let text = try Type4MeTransferCodec.encodeText(sample)
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let wrapped = "我的配置：\n" + text[..<middle] + "\n  " + text[middle...] + "\n谢谢"
        XCTAssertEqual(try Type4MeTransferCodec.decode(String(wrapped)), sample)
    }

    func testDecodesPercentEncodedURL() throws {
        let url = try Type4MeTransferCodec.encodeURL(sample)
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        XCTAssertEqual(try Type4MeTransferCodec.decode(encoded), sample)
    }

    func testRejectsTextWithoutMarker() {
        XCTAssertThrowsError(try Type4MeTransferCodec.decode("hello")) { error in
            XCTAssertEqual(error as? Type4MeTransferError, .notFound)
        }
        XCTAssertFalse(Type4MeTransferCodec.containsToken("hello"))
    }

    func testRejectsTruncatedText() throws {
        let text = try Type4MeTransferCodec.encodeText(sample)
        XCTAssertThrowsError(try Type4MeTransferCodec.decode(String(text.prefix(40)))) { error in
            XCTAssertEqual(error as? Type4MeTransferError, .corrupted)
        }
    }

    func testRejectsNewerVersion() throws {
        var newer = sample
        newer.version = Type4MeTransferPayload.currentVersion + 1
        let text = try Type4MeTransferCodec.encodeText(newer)
        XCTAssertThrowsError(try Type4MeTransferCodec.decode(text)) { error in
            XCTAssertEqual(error as? Type4MeTransferError, .unsupportedVersion(newer.version))
        }
    }

    func testRejectsPayloadWithoutEndpoints() throws {
        let empty = Type4MeTransferPayload(asr: nil, llm: nil)
        let text = try Type4MeTransferCodec.encodeText(empty)
        XCTAssertThrowsError(try Type4MeTransferCodec.decode(text)) { error in
            XCTAssertEqual(error as? Type4MeTransferError, .empty)
        }
    }

    // MARK: - Version 2: modes, several text models, multi-code

    private var bigPayload: Type4MeTransferPayload {
        var payload = sample
        payload.llmProfiles = [
            .init(provider: "kimi", fields: ["apiKey": "sk-kimi-0123456789", "model": "kimi-k2", "baseURL": "https://api.moonshot.cn/v1"]),
        ]
        payload.modes = [
            .init(id: "formalWriting", kind: Type4MeTransferPayload.Mode.Kind.formalWriting, name: nil, prompt: nil),
            .init(id: "mac-5d0a24d4", kind: Type4MeTransferPayload.Mode.Kind.custom, name: "Prompt优化",
                  prompt: String(repeating: "把口述需求整理成结构清晰、可以直接交给模型的 Prompt。保留所有约束和例子。\n", count: 40) + "{text}"),
            .init(id: "mac-c4e8f2a1", kind: Type4MeTransferPayload.Mode.Kind.custom, name: "代办模式",
                  prompt: String(repeating: "Speak a request and get a ready-to-use result. Keep the user's language. ", count: 30)),
        ]
        return payload
    }

    /// Payloads written by the first iPhone build still import.
    func testDecodesVersionOneText() throws {
        let json = try JSONEncoder().encode(Type4MeTransferPayload(version: 1, asr: sample.asr, llm: sample.llm))
        let v1 = Type4MeTransferCodec.textPrefix + Type4MeTransferCodec.base64URLEncode(json)
        let decoded = try Type4MeTransferCodec.decode(v1)
        XCTAssertEqual(decoded.asr, sample.asr)
        XCTAssertEqual(decoded.llm, sample.llm)
    }

    func testModesAndProfilesRoundTrip() throws {
        let text = try Type4MeTransferCodec.encodeText(bigPayload)
        let decoded = try Type4MeTransferCodec.decode(text)
        XCTAssertEqual(decoded, bigPayload)
        XCTAssertEqual(decoded.allLLMs.map(\.provider), ["deepseek", "kimi"])
    }

    func testSpeechProfilesRoundTripActiveFirst() throws {
        var payload = sample
        payload.asrProfiles = [
            .init(provider: "soniox", fields: ["apiKey": "soniox-key"]),
            .init(provider: "volcano", fields: ["apiKey": "duplicate"]),
        ]
        let decoded = try Type4MeTransferCodec.decode(try Type4MeTransferCodec.encodeText(payload))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.allASRs.map(\.provider), ["volcano", "soniox"])
        XCTAssertEqual(decoded.allASRs.first, sample.asr)
    }

    func testSpeechProfilesAloneAreNotEmpty() throws {
        let payload = Type4MeTransferPayload(asr: nil, asrProfiles: [.init(provider: "soniox", fields: ["apiKey": "k"])], llm: nil)
        XCTAssertEqual(try Type4MeTransferCodec.decode(try Type4MeTransferCodec.encodeText(payload)).allASRs.count, 1)
    }

    func testTranslationTargetRoundTripsAndIsOptional() throws {
        let mode = Type4MeTransferPayload.Mode(id: "translateEnglish", kind: "translateEnglish", name: nil, prompt: nil, targetLanguage: "ja")
        let payload = Type4MeTransferPayload(asr: nil, llm: nil, modes: [mode])
        XCTAssertEqual(try Type4MeTransferCodec.decode(try Type4MeTransferCodec.encodeText(payload)).modes?.first?.targetLanguage, "ja")
        let older = try JSONDecoder().decode(Type4MeTransferPayload.Mode.self, from: Data(#"{"i":"translateEnglish","k":"translateEnglish"}"#.utf8))
        XCTAssertNil(older.targetLanguage)
    }

    func testModesOnlyPayloadIsNotEmpty() throws {
        let payload = Type4MeTransferPayload(asr: nil, llm: nil, modes: [.init(id: "quick", kind: "quick", name: "快", prompt: nil)])
        XCTAssertEqual(try Type4MeTransferCodec.decode(try Type4MeTransferCodec.encodeText(payload)), payload)
    }

    func testSmallPayloadIsOneCode() throws {
        let frames = try Type4MeTransferCodec.encodeFrames(sample)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try Type4MeTransferCodec.decode(frames[0]), sample)
    }

    func testLargePayloadSplitsAndAssemblesInAnyOrderWithRepeats() throws {
        let frames = try Type4MeTransferCodec.encodeFrames(bigPayload, chunkSize: 300)
        XCTAssertGreaterThan(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.count < 400 && URL(string: $0) != nil })
        XCTAssertThrowsError(try Type4MeTransferCodec.decode(frames[0])) { error in
            XCTAssertEqual(error as? Type4MeTransferError, .partial)
        }

        var assembler = Type4MeTransferAssembler()
        var result: Type4MeTransferPayload?
        // The scanner sees the cycling codes repeatedly and out of order.
        let order = Array(frames.indices.reversed()) + [0, 0] + Array(frames.indices)
        for index in order {
            switch assembler.add(frames[index]) {
            case .complete(let payload): result = payload
            case .progress(let received, let total):
                XCTAssertEqual(total, frames.count)
                XCTAssertTrue(received.contains(Type4MeTransferCodec.Part(frames[index])!.index))
            default: XCTFail("unexpected status")
            }
            if result != nil { break }
        }
        XCTAssertEqual(result, bigPayload)
    }

    /// The Mac changed the selection mid-scan: the old parts are dropped.
    func testNewGroupStartsOver() throws {
        let first = try Type4MeTransferCodec.encodeFrames(bigPayload, chunkSize: 300)
        var other = bigPayload
        other.sourceName = "Mac mini"
        let second = try Type4MeTransferCodec.encodeFrames(other, chunkSize: 300)

        var assembler = Type4MeTransferAssembler()
        _ = assembler.add(first[0])
        _ = assembler.add(first[1])
        guard case .progress(let received, _) = assembler.add(second[0]) else { return XCTFail("expected progress") }
        XCTAssertEqual(received, [1])
        var result: Type4MeTransferPayload?
        for frame in second.dropFirst() {
            if case .complete(let payload) = assembler.add(frame) { result = payload }
        }
        XCTAssertEqual(result, other)
    }

    func testAssemblerIgnoresUnrelatedCodes() {
        var assembler = Type4MeTransferAssembler()
        XCTAssertEqual(assembler.add("https://example.com"), .ignored)
    }

    // MARK: - Vocabulary

    func testVocabularyRoundTrips() throws {
        let payload = Type4MeTransferPayload(
            asr: nil,
            llm: nil,
            hotwords: ["Claude Code", "Type4Me"],
            snippets: [.init(trigger: "cloud code", replacement: "Claude Code")]
        )
        XCTAssertFalse(payload.isEmpty, "vocabulary alone is worth syncing")
        XCTAssertEqual(try Type4MeTransferCodec.decode(Type4MeTransferCodec.encodeText(payload)), payload)
    }

    func testPayloadWithoutVocabularyStillDecodes() throws {
        let decoded = try Type4MeTransferCodec.decode(Type4MeTransferCodec.encodeText(sample))
        XCTAssertNil(decoded.hotwords)
        XCTAssertNil(decoded.snippets)
    }

    func testSnippetPatternIgnoresCaseAndSpaces() {
        let rules: [Type4MeTransferPayload.Snippet] = [
            .init(trigger: "Cloud Code", replacement: "Claude Code"),
            .init(trigger: "Jason", replacement: "JSON"),
        ]
        XCTAssertEqual(SnippetPattern.apply(rules, to: "用 cloudcode 写 jason"), "用 Claude Code 写 JSON")
        XCTAssertEqual(SnippetPattern.apply(rules, to: "Jasonette"), "Jasonette", "only whole Latin words match")
        XCTAssertEqual(SnippetPattern.apply([.init(trigger: "价格", replacement: "$1 起")], to: "价格"), "$1 起", "replacement is literal")
    }
}
