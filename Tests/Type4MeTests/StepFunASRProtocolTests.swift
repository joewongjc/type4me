import XCTest
@testable import Type4Me

final class StepFunASRProtocolTests: XCTestCase {

    func testSessionUpdateUsesManualCommitAndHotwordPrompt() throws {
        let message = StepFunASRProtocol.buildSessionUpdateMessage(options: ASRRequestOptions(
            hotwords: [" Type4Me ", "", "type4me", "阶跃星辰"]
        ))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "session.update")
        XCTAssertNotNil(json["event_id"] as? String)

        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "pcm")
        XCTAssertEqual(format["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(format["rate"] as? Int, 16_000)
        XCTAssertEqual(format["bits"] as? Int, 16)
        XCTAssertEqual(format["channel"] as? Int, 1)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, StepFunASRConfig.model)
        XCTAssertEqual(transcription["language"] as? String, "zh")
        XCTAssertEqual(transcription["full_rerun_on_commit"] as? Bool, true)
        XCTAssertEqual(transcription["enable_itn"] as? Bool, true)
        XCTAssertEqual(transcription["prompt"] as? String, "专业术语：Type4Me、阶跃星辰")
        XCTAssertNil(input["turn_detection"])
    }

    func testSessionUpdateSanitizesAndBoundsHotwordPrompt() throws {
        let oversizedTerms = (0..<120).map { "术语\($0)-" + String(repeating: "字", count: 30) }
        let message = StepFunASRProtocol.buildSessionUpdateMessage(options: ASRRequestOptions(
            hotwords: [" Type4Me ", "type4me", "TYPE4ME"] + oversizedTerms
        ))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        let prompt = try XCTUnwrap(transcription["prompt"] as? String)

        XCTAssertTrue(prompt.hasPrefix("专业术语：Type4Me"))
        XCTAssertEqual(prompt.components(separatedBy: "Type4Me").count - 1, 1)
        XCTAssertLessThanOrEqual(prompt.count, 2_000)
        XCTAssertLessThanOrEqual(prompt.split(separator: "、").count, 100)
    }

    func testSessionUpdateOmitsPromptWhenHotwordsAreBlank() throws {
        let message = StepFunASRProtocol.buildSessionUpdateMessage(options: ASRRequestOptions(
            hotwords: ["", "   ", "\n"]
        ))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])

        XCTAssertNil(transcription["prompt"])
    }

    func testAppendMessageEncodesRawPCM() throws {
        let pcm = Data([0x00, 0x7f, 0xff])
        let message = StepFunASRProtocol.buildAppendAudioMessage(pcm)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json["audio"] as? String, pcm.base64EncodedString())
        XCTAssertNotNil(json["event_id"] as? String)
    }

    func testCommitMessage() throws {
        let message = StepFunASRProtocol.buildCommitMessage()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.commit")
        XCTAssertNotNil(json["event_id"] as? String)
    }

    func testDeltaUsesTextAsConfirmedPrefixAndStashAsPartial() throws {
        let data = Data(#"{"type":"conversation.item.input_audio_transcription.delta","text":"你好，","stash":"世界"}"#.utf8)
        let event = try StepFunASRProtocol.parseServerEvent(from: data)

        guard case .transcript(let transcript) = event else {
            return XCTFail("Expected transcript event")
        }
        XCTAssertEqual(transcript.confirmedSegments, ["你好，"])
        XCTAssertEqual(transcript.partialText, "世界")
        XCTAssertEqual(transcript.authoritativeText, "你好，世界")
        XCTAssertFalse(transcript.isFinal)
    }

    func testCompletedTranscriptIsFinalAndAuthoritative() throws {
        let data = Data(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好，世界"}"#.utf8)
        let event = try StepFunASRProtocol.parseServerEvent(from: data)

        guard case .transcript(let transcript) = event else {
            return XCTFail("Expected transcript event")
        }
        XCTAssertEqual(transcript.confirmedSegments, ["你好，世界"])
        XCTAssertEqual(transcript.partialText, "")
        XCTAssertEqual(transcript.authoritativeText, "你好，世界")
        XCTAssertTrue(transcript.isFinal)
    }

    func testSessionUpdatedMarksSessionReady() throws {
        let data = Data(#"{"type":"session.updated"}"#.utf8)
        XCTAssertEqual(try StepFunASRProtocol.parseServerEvent(from: data), .sessionReady)
    }

    func testErrorMessagePreservesCodeAndMessage() throws {
        let data = Data(#"{"type":"error","error":{"code":"invalid_value","message":"bad audio"}}"#.utf8)
        XCTAssertEqual(
            try StepFunASRProtocol.parseServerEvent(from: data),
            .error(.serverError(code: "invalid_value", message: "bad audio"))
        )
    }

    func testUnknownEventIsIgnored() throws {
        let data = Data(#"{"type":"session.created"}"#.utf8)
        XCTAssertNil(try StepFunASRProtocol.parseServerEvent(from: data))
    }
}
