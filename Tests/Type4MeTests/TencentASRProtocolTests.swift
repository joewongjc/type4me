import XCTest
@testable import Type4Me

final class TencentASRProtocolTests: XCTestCase {

    // MARK: - Message Decoding

    func testDecode_resultWireFormat() {
        let json = """
        {
            "code": 0,
            "message": "success",
            "voice_id": "test-voice-id",
            "result": {
                "slice_type": 1,
                "index": 0,
                "voice_text_str": "我们这周要把",
                "start_time": 0,
                "end_time": 1100
            }
        }
        """
        let msg = TencentRealtimeMessage.decode(from: Data(json.utf8))
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.code, 0)
        XCTAssertEqual(msg?.updates.count, 1)
        XCTAssertEqual(msg?.updates.first?.id, 0)
        XCTAssertEqual(msg?.updates.first?.text, "我们这周要把")
        XCTAssertFalse(msg?.updates.first?.isFinal ?? true)
        XCTAssertFalse(msg?.isFinal ?? true)
    }

    func testDecode_resultWireFormatFinalSlice() {
        let json = """
        {
            "code": 0,
            "message": "success",
            "result": {
                "slice_type": 2,
                "index": 0,
                "voice_text_str": "我们这周要把项目完成。"
            }
        }
        """
        let msg = TencentRealtimeMessage.decode(from: Data(json.utf8))
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.updates.first?.isFinal, true)
    }

    func testDecode_sentencesWireFormat() {
        let json = """
        {
            "code": 0,
            "sentences": [
                {
                    "sentence_id": 1,
                    "sentence": "实时语音识别。",
                    "sentence_type": 1
                }
            ]
        }
        """
        let msg = TencentRealtimeMessage.decode(from: Data(json.utf8))
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.updates.count, 1)
        XCTAssertEqual(msg?.updates.first?.id, 1)
        XCTAssertEqual(msg?.updates.first?.text, "实时语音识别。")
        XCTAssertTrue(msg?.updates.first?.isFinal ?? false)
    }

    func testDecode_sessionFinalMessage() {
        let json = """
        {
            "code": 0,
            "final": 1,
            "message": "success"
        }
        """
        let msg = TencentRealtimeMessage.decode(from: Data(json.utf8))
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg?.isFinal ?? false)
        XCTAssertTrue(msg?.updates.isEmpty ?? false)
    }

    // MARK: - State Machine

    func testTranscriptState_appliesProgressiveUpdatesAndPreservesFinal() {
        var state = TencentTranscriptState()

        // Sentence 0: interim
        state.apply(TencentSentenceUpdate(id: 0, text: "今天", isFinal: false))
        XCTAssertEqual(state.transcript.partialText, "今天")
        XCTAssertEqual(state.transcript.confirmedSegments, [])

        // Sentence 0: revised interim
        state.apply(TencentSentenceUpdate(id: 0, text: "今天下午3点", isFinal: false))
        XCTAssertEqual(state.transcript.partialText, "今天下午3点")

        // Sentence 0: finalized
        state.apply(TencentSentenceUpdate(id: 0, text: "今天下午3点。", isFinal: true))
        XCTAssertEqual(state.transcript.confirmedSegments, ["今天下午3点。"])
        XCTAssertEqual(state.transcript.partialText, "")

        // Sentence 0 receives late interim -> should be ignored!
        state.apply(TencentSentenceUpdate(id: 0, text: "今天", isFinal: false))
        XCTAssertEqual(state.transcript.confirmedSegments, ["今天下午3点。"])

        // Sentence 1: interim
        state.apply(TencentSentenceUpdate(id: 1, text: "开会", isFinal: false))
        XCTAssertEqual(state.transcript.confirmedSegments, ["今天下午3点。"])
        XCTAssertEqual(state.transcript.partialText, "开会")
        XCTAssertEqual(state.transcript.authoritativeText, "今天下午3点。开会")

        // Mark final on session completion
        state.markFinal()
        XCTAssertTrue(state.transcript.isFinal)
        XCTAssertEqual(state.transcript.authoritativeText, "今天下午3点。开会")
    }

    func testTranscriptState_staysNonFinalWhenInterruptedBeforeFinal() {
        var state = TencentTranscriptState()
        state.apply(TencentSentenceUpdate(id: 0, text: "说了一半的话", isFinal: false))
        XCTAssertFalse(state.transcript.isFinal)
        XCTAssertEqual(state.transcript.partialText, "说了一半的话")
        XCTAssertEqual(state.transcript.confirmedSegments, [])
    }

    // MARK: - Hotwords Formatting

    func testHotwordsFormatting() {
        let hotwords = [
            "Type4Me", // valid English
            "语音识别", // valid Chinese (4 Han chars <= 10)
            "Claude Code", // contains space -> skip
            "A,B", // contains comma -> skip
            "一二三四五六七八九十一", // 11 Han chars > 10 -> skip
            "ThisIsAThirtyOneCharacterWord!!!", // 32 chars > 30 -> skip
        ]

        let result = TencentHotwords.formatList(from: hotwords)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "Type4Me|10,语音识别|10")
    }

    // MARK: - Error Mapping

    func testErrorMapping() {
        XCTAssertTrue(TencentASRError.server(code: 4002, message: "auth fail").localizedDescription.contains("4002"))
        XCTAssertTrue(TencentASRError.server(code: 6001, message: "overseas").localizedDescription.contains("6001"))
        XCTAssertTrue(TencentASRError.taskFailed(code: "AuthFailure.SignatureFailure", message: "fail").localizedDescription.contains("SecretId"))
    }
}
