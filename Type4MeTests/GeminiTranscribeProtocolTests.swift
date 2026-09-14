import XCTest
@testable import Type4Me

final class GeminiTranscribeProtocolTests: XCTestCase {

    func testBuildWebSocketURL_encodesKeyQueryParameter() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "AIzaSyTestKey123_special+value"]))
        let url = try GeminiTranscribeProtocol.buildWebSocketURL(config: config)

        XCTAssertTrue(url.absoluteString.starts(with: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let keyItem = components.queryItems?.first { $0.name == "key" }
        XCTAssertEqual(keyItem?.value, "AIzaSyTestKey123_special+value")
    }

    func testRedactedURLString_masksAPIKey() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "SECRET_KEY_999"]))
        let url = try GeminiTranscribeProtocol.buildWebSocketURL(config: config)
        let redacted = GeminiTranscribeProtocol.redactedURLString(for: url)

        XCTAssertFalse(redacted.contains("SECRET_KEY_999"))
        XCTAssertTrue(redacted.contains("key=REDACTED"))
    }

    func testSetupMessage_autoLanguageAndSmartMode() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "test-key", "mode": "SMART", "languageCode": "auto"]))
        let options = ASRRequestOptions(hotwords: ["Type4Me", "SwiftUI", "Type4Me", "   ", "OpenAI"])
        let setupJSON = try GeminiTranscribeProtocol.setupMessage(config: config, options: options)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setupJSON.utf8)) as? [String: Any])
        let setup = try XCTUnwrap(root["setup"] as? [String: Any])

        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")

        let genConfig = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(genConfig["responseModalities"] as? [String], ["TEXT"])

        let realtimeConfig = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        let autoVAD = try XCTUnwrap(realtimeConfig["automaticActivityDetection"] as? [String: Any])
        XCTAssertEqual(autoVAD["disabled"] as? Bool, true)

        let transcribeConfig = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcribeConfig["mode"] as? String, "SMART")
        XCTAssertEqual(transcribeConfig["languageCodes"] as? [String], [])

        let vocab = try XCTUnwrap(transcribeConfig["customVocabulary"] as? [String])
        XCTAssertEqual(vocab, ["Type4Me", "SwiftUI", "OpenAI"])
    }

    func testSetupMessage_explicitLanguageAndVerbatimMode() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "test-key", "mode": "VERBATIM", "languageCode": "cmn-Hans-CN"]))
        let options = ASRRequestOptions()
        let setupJSON = try GeminiTranscribeProtocol.setupMessage(config: config, options: options)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setupJSON.utf8)) as? [String: Any])
        let setup = try XCTUnwrap(root["setup"] as? [String: Any])
        let transcribeConfig = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])

        XCTAssertEqual(transcribeConfig["mode"] as? String, "VERBATIM")
        XCTAssertEqual(transcribeConfig["languageCodes"] as? [String], ["cmn-Hans-CN"])
        XCTAssertNil(transcribeConfig["customVocabulary"])
    }

    func testCustomVocabulary_deDuplicatesAndCapsAt1000() {
        var input: [String] = []
        for i in 0..<1200 {
            input.append("word\(i)")
            input.append("word\(i)") // duplicate
        }
        let sanitized = GeminiTranscribeProtocol.sanitizeHotwords(input)
        XCTAssertEqual(sanitized.count, 1000)
        XCTAssertEqual(sanitized.first, "word0")
        XCTAssertEqual(sanitized.last, "word999")
    }

    func testActivityMessages() throws {
        let startJSON = GeminiTranscribeProtocol.activityStartMessage()
        let startDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(startJSON.utf8)) as? [String: Any])
        let startRealtime = try XCTUnwrap(startDict["realtimeInput"] as? [String: Any])
        XCTAssertNotNil(startRealtime["activityStart"])

        let endJSON = GeminiTranscribeProtocol.activityEndMessage()
        let endDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(endJSON.utf8)) as? [String: Any])
        let endRealtime = try XCTUnwrap(endDict["realtimeInput"] as? [String: Any])
        XCTAssertNotNil(endRealtime["activityEnd"])
    }

    func testAudioChunkMessage_encodesBase64() throws {
        let originalBytes = (0..<100).map { UInt8($0) }
        let pcmData = Data(originalBytes)
        let chunkJSON = GeminiTranscribeProtocol.audioChunkMessage(pcmData)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chunkJSON.utf8)) as? [String: Any])
        let realtime = try XCTUnwrap(root["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtime["audio"] as? [String: Any])

        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        let base64String = try XCTUnwrap(audio["data"] as? String)
        let decodedData = try XCTUnwrap(Data(base64Encoded: base64String))
        XCTAssertEqual(decodedData, pcmData)
    }

    func testMakeTranscriptUpdate_setupComplete() throws {
        let json = #"{"setupComplete": {}}"#
        let update = try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: ["Previously"],
            didEndAudio: false
        )
        XCTAssertNotNil(update)
        XCTAssertTrue(update?.isSetupComplete ?? false)
    }

    func testMakeTranscriptUpdate_interimTranscription() throws {
        let json = #"{"serverContent": {"interimInputTranscription": {"text": "hello world"}}}"#
        let update = try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: ["Hi."],
            didEndAudio: false
        )
        let unwrapped = try XCTUnwrap(update)
        XCTAssertFalse(unwrapped.isSetupComplete)
        XCTAssertEqual(unwrapped.transcript.confirmedSegments, ["Hi."])
        XCTAssertEqual(unwrapped.transcript.partialText, " hello world")
        XCTAssertEqual(unwrapped.transcript.authoritativeText, "Hi. hello world")
        XCTAssertFalse(unwrapped.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_dropsPureHotwordInterim() throws {
        let json = #"{"serverContent": {"interimInputTranscription": {"text": "Type4Me Qwen Deepgram"}}}"#
        let update = try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: [],
            didEndAudio: false,
            hotwords: ["Type4Me", "Qwen", "Deepgram"]
        )

        XCTAssertNil(update)
    }

    func testMakeTranscriptUpdate_dropsPureHotwordFinalAndCompletes() throws {
        let json = #"{"serverContent": {"inputTranscription": {"text": "Type4Me Qwen Deepgram"}}}"#
        let update = try XCTUnwrap(try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: [],
            didEndAudio: true,
            hotwords: ["Type4Me", "Qwen", "Deepgram"]
        ))

        XCTAssertTrue(update.transcript.isFinal)
        XCTAssertEqual(update.transcript.displayText, "")
        XCTAssertTrue(update.confirmedSegments.isEmpty)
    }

    func testMakeTranscriptUpdate_keepsSingleHotwordUtterance() throws {
        let json = #"{"serverContent": {"interimInputTranscription": {"text": "Qwen"}}}"#
        let update = try XCTUnwrap(try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: [],
            didEndAudio: false,
            hotwords: ["Qwen"]
        ))

        XCTAssertEqual(update.transcript.displayText, "Qwen")
    }

    func testMakeTranscriptUpdate_finalTranscriptionBeforeEndAudio() throws {
        let json = #"{"serverContent": {"inputTranscription": {"text": "Hello world"}}}"#
        let update = try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: [],
            didEndAudio: false
        )
        let unwrapped = try XCTUnwrap(update)
        XCTAssertEqual(unwrapped.confirmedSegments, ["Hello world"])
        XCTAssertEqual(unwrapped.transcript.partialText, "")
        XCTAssertEqual(unwrapped.transcript.authoritativeText, "Hello world")
        XCTAssertFalse(unwrapped.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_finalTranscriptionAfterEndAudio() throws {
        let json = #"{"serverContent": {"inputTranscription": {"text": "Final sentence."}}}"#
        let update = try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: ["Part 1."],
            didEndAudio: true
        )
        let unwrapped = try XCTUnwrap(update)
        XCTAssertEqual(unwrapped.confirmedSegments, ["Part 1.", " Final sentence."])
        XCTAssertEqual(unwrapped.transcript.partialText, "")
        XCTAssertEqual(unwrapped.transcript.authoritativeText, "Part 1. Final sentence.")
        XCTAssertTrue(unwrapped.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_quotaExceededError() {
        let json = #"{"error": {"code": 429, "message": "Resource has been exhausted", "status": "RESOURCE_EXHAUSTED"}}"#
        XCTAssertThrowsError(try GeminiTranscribeProtocol.makeTranscriptUpdate(
            from: Data(json.utf8),
            confirmedSegments: [],
            didEndAudio: false
        )) { error in
            guard let geminiErr = error as? GeminiASRError else {
                XCTFail("Expected GeminiASRError, got \(error)")
                return
            }
            XCTAssertEqual(geminiErr, .quotaExceeded("Resource has been exhausted"))
        }
    }

    func testRechunkAudioPayloads() {
        var buffer = Data()

        // 1. Append 6400 bytes (standard 200ms input) -> two 3200-byte payloads
        let chunk6400 = Data(repeating: 0x42, count: 6400)
        buffer.append(chunk6400)
        let payloads1 = GeminiTranscribeProtocol.sliceAudioPayloads(from: &buffer)
        XCTAssertEqual(payloads1.count, 2)
        XCTAssertEqual(payloads1[0].count, 3200)
        XCTAssertEqual(payloads1[1].count, 3200)
        XCTAssertTrue(buffer.isEmpty)

        // 2. Incremental appends: 1000 then 2200 bytes -> 1 payload of 3200
        buffer.append(Data(repeating: 0x01, count: 1000))
        let payloads2a = GeminiTranscribeProtocol.sliceAudioPayloads(from: &buffer)
        XCTAssertEqual(payloads2a.count, 0)
        XCTAssertEqual(buffer.count, 1000)

        buffer.append(Data(repeating: 0x02, count: 2200))
        let payloads2b = GeminiTranscribeProtocol.sliceAudioPayloads(from: &buffer)
        XCTAssertEqual(payloads2b.count, 1)
        XCTAssertEqual(payloads2b[0].count, 3200)
        XCTAssertTrue(buffer.isEmpty)

        // 3. Flush residual audio
        buffer.append(Data(repeating: 0x03, count: 500))
        let flushed = GeminiTranscribeProtocol.flushResidualAudio(from: &buffer)
        XCTAssertEqual(flushed?.count, 500)
        XCTAssertTrue(buffer.isEmpty)

        // 4. Batch fallback scale: 1.92 MB (60 seconds at 16kHz 16-bit mono = 1,920,000 bytes)
        let fullRecording = Data(repeating: 0x55, count: 1_920_000)
        buffer.append(fullRecording)
        let batchPayloads = GeminiTranscribeProtocol.sliceAudioPayloads(from: &buffer)
        XCTAssertEqual(batchPayloads.count, 600) // 1,920,000 / 3200 = 600
        XCTAssertTrue(buffer.isEmpty)

        var reconstructed = Data()
        for p in batchPayloads {
            reconstructed.append(p)
        }
        XCTAssertEqual(reconstructed, fullRecording)
    }

    func testSegmentNormalization() {
        // CJK segments - no space added
        XCTAssertEqual(GeminiTranscribeProtocol.normalize(segment: "世界", after: "你好"), "世界")

        // Latin segments - space added
        XCTAssertEqual(GeminiTranscribeProtocol.normalize(segment: "world", after: "hello"), " world")

        // Already has leading whitespace
        XCTAssertEqual(GeminiTranscribeProtocol.normalize(segment: " world", after: "hello"), " world")

        // Punctuation handling
        XCTAssertEqual(GeminiTranscribeProtocol.normalize(segment: "，你好", after: "今天"), "，你好")
    }

    // MARK: - Model selection

    func testSetupMessage_usesConfiguredModel() throws {
        let config = try XCTUnwrap(GeminiASRConfig(credentials: [
            "apiKey": "test-key",
            "model": "gemini-4-transcribe-live"
        ]))
        let setupJSON = try GeminiTranscribeProtocol.setupMessage(config: config, options: ASRRequestOptions())

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setupJSON.utf8)) as? [String: Any])
        let setup = try XCTUnwrap(root["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-4-transcribe-live")
    }

    func testQualifiedModelName_normalizesUserInput() {
        XCTAssertEqual(
            GeminiTranscribeProtocol.qualifiedModelName("gemini-3.5-transcribe-live"),
            "models/gemini-3.5-transcribe-live"
        )
        // Users may paste the fully qualified name; it must not be doubled up.
        XCTAssertEqual(
            GeminiTranscribeProtocol.qualifiedModelName("models/gemini-3.5-transcribe-live"),
            "models/gemini-3.5-transcribe-live"
        )
        XCTAssertEqual(
            GeminiTranscribeProtocol.qualifiedModelName("  gemini-4-transcribe-live \n"),
            "models/gemini-4-transcribe-live"
        )
        XCTAssertEqual(
            GeminiTranscribeProtocol.qualifiedModelName("   "),
            "models/\(GeminiASRConfig.defaultModel)"
        )
        XCTAssertEqual(
            GeminiTranscribeProtocol.qualifiedModelName("models/"),
            "models/\(GeminiASRConfig.defaultModel)"
        )
    }
}
