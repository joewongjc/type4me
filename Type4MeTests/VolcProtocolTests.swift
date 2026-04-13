import XCTest
@testable import Type4Me

final class VolcProtocolTests: XCTestCase {

    // MARK: - Header Encoding

    func testHeaderEncoding_fullClientRequest() {
        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        let data = header.encode()
        XCTAssertEqual(data.count, 4)
        // Byte 0: version=1 (0001) | headerSize=1 (0001) => 0x11
        XCTAssertEqual(data[0], 0x11)
        // Byte 1: msgType=0001 | flags=0000 => 0x10
        XCTAssertEqual(data[1], 0x10)
        // Byte 2: serialization=0001 | compression=0001 => 0x11
        XCTAssertEqual(data[2], 0x11)
        // Byte 3: reserved
        XCTAssertEqual(data[3], 0x00)
    }

    func testHeaderEncoding_audioData() {
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: .positiveSequence,
            serialization: .none,
            compression: .none
        )
        let data = header.encode()
        XCTAssertEqual(data.count, 4)
        // Byte 0: 0x11
        XCTAssertEqual(data[0], 0x11)
        // Byte 1: msgType=0010 | flags=0001 => 0x21
        XCTAssertEqual(data[1], 0x21)
        // Byte 2: ser=0000 | comp=0000 => 0x00
        XCTAssertEqual(data[2], 0x00)
        XCTAssertEqual(data[3], 0x00)
    }

    func testHeaderEncoding_lastAudioPacket() {
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: .negativeSequenceLast,
            serialization: .none,
            compression: .none
        )
        let data = header.encode()
        // Byte 1: msgType=0010 | flags=0011 => 0x23
        XCTAssertEqual(data[1], 0x23)
    }

    // MARK: - Header Decoding

    func testHeaderDecoding_serverResponse() throws {
        let raw = Data([0x11, 0x90, 0x11, 0x00])
        let header = try VolcHeader.decode(from: raw)
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.headerSize, 1)
        XCTAssertEqual(header.messageType, .serverResponse)
        XCTAssertEqual(header.flags, .noSequence)
        XCTAssertEqual(header.serialization, .json)
        XCTAssertEqual(header.compression, .gzip)
    }

    func testHeaderDecoding_serverError() throws {
        let raw = Data([0x11, 0xF0, 0x10, 0x00])
        let header = try VolcHeader.decode(from: raw)
        XCTAssertEqual(header.messageType, .serverError)
        XCTAssertEqual(header.serialization, .json)
        XCTAssertEqual(header.compression, .none)
    }

    func testHeaderDecoding_asyncFinal() throws {
        let raw = Data([0x11, 0x94, 0x10, 0x00])
        let header = try VolcHeader.decode(from: raw)
        XCTAssertEqual(header.messageType, .serverResponse)
        XCTAssertEqual(header.flags, .asyncFinal)
        XCTAssertEqual(header.flags.hasSequence, false)
    }

    func testHeaderDecoding_tooShort() {
        let raw = Data([0x11, 0x90])
        XCTAssertThrowsError(try VolcHeader.decode(from: raw))
    }

    // MARK: - Client Request JSON

    func testClientRequestJSON() throws {
        let payload = VolcProtocol.buildClientRequest(uid: "test-user-123")
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertNotNil(json)

        let user = json?["user"] as? [String: Any]
        XCTAssertEqual(user?["uid"] as? String, "test-user-123")

        let audio = json?["audio"] as? [String: Any]
        XCTAssertEqual(audio?["format"] as? String, "pcm")
        XCTAssertEqual(audio?["codec"] as? String, "raw")
        XCTAssertEqual(audio?["rate"] as? Int, 16000)

        let request = json?["request"] as? [String: Any]
        XCTAssertEqual(request?["show_utterances"] as? Bool, true)
        XCTAssertEqual(request?["result_type"] as? String, "full")
        XCTAssertEqual(request?["enable_nonstream"] as? Bool, true)
        XCTAssertEqual(request?["enable_ddc"] as? Bool, true)
        XCTAssertNil(request?["context"])
    }

    func testClientRequestJSON_usesHotwordsAndBoostingCorpusFields() throws {
        // With a cloud boosting table ID, inline hotwords are omitted (table takes precedence).
        let payload = VolcProtocol.buildClientRequest(
            uid: "test-user-123",
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: ["Type4Me", "DeepSeek"],
                boostingTableID: "boost-123",
                contextHistoryLength: 6
            )
        )
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let request = json?["request"] as? [String: Any]
        XCTAssertEqual(request?["context_history_length"] as? Int, 6)
        XCTAssertNil(request?["context"])

        let corpus = try XCTUnwrap(request?["corpus"] as? [String: Any])
        XCTAssertEqual(corpus["boosting_table_id"] as? String, "boost-123")
    }

    func testClientRequestJSON_usesInlineHotwordsWhenNoBoostingTable() throws {
        let payload = VolcProtocol.buildClientRequest(
            uid: "test-user-123",
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: ["Type4Me", "DeepSeek"],
                boostingTableID: nil,
                contextHistoryLength: 6
            )
        )
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let request = try XCTUnwrap(json?["request"] as? [String: Any])
        let contextString = try XCTUnwrap(request["context"] as? String)
        let contextData = try XCTUnwrap(contextString.data(using: .utf8))
        let context = try JSONSerialization.jsonObject(with: contextData) as? [String: Any]
        let hotwords = try XCTUnwrap(context?["hotwords"] as? [[String: Any]])
        XCTAssertEqual(hotwords.count, 2)
        XCTAssertEqual(hotwords.first?["word"] as? String, "Type4Me")
        XCTAssertNil(request["corpus"])
    }

    // MARK: - Full Message Encoding

    func testEncodeMessage_withSequenceNumber() {
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: .positiveSequence,
            serialization: .none,
            compression: .none
        )
        let audio = Data([0xAA, 0xBB, 0xCC])
        let message = VolcProtocol.encodeMessage(
            header: header,
            payload: audio,
            sequenceNumber: 1
        )
        // 4 (header) + 4 (seq) + 4 (size) + 3 (payload) = 15
        XCTAssertEqual(message.count, 15)

        // Check sequence number (big-endian 1)
        XCTAssertEqual(message[4], 0x00)
        XCTAssertEqual(message[5], 0x00)
        XCTAssertEqual(message[6], 0x00)
        XCTAssertEqual(message[7], 0x01)

        // Check payload size (big-endian 3)
        XCTAssertEqual(message[8], 0x00)
        XCTAssertEqual(message[9], 0x00)
        XCTAssertEqual(message[10], 0x00)
        XCTAssertEqual(message[11], 0x03)

        // Check payload
        XCTAssertEqual(message[12], 0xAA)
        XCTAssertEqual(message[13], 0xBB)
        XCTAssertEqual(message[14], 0xCC)
    }

    func testEncodeMessage_noSequenceNumber() {
        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let payload = Data([0x01, 0x02])
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)
        // 4 (header) + 4 (size) + 2 (payload) = 10
        XCTAssertEqual(message.count, 10)

        // Payload size at offset 4
        XCTAssertEqual(message[4], 0x00)
        XCTAssertEqual(message[5], 0x00)
        XCTAssertEqual(message[6], 0x00)
        XCTAssertEqual(message[7], 0x02)
    }

    // MARK: - Audio Packet Encoding

    func testEncodeAudioPacket_normal() {
        let audio = Data(repeating: 0x55, count: 10)
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: audio,
            isLast: false
        )
        // Header byte 1: audioOnly=0010 | noSequence=0000 => 0x20
        XCTAssertEqual(packet[1], 0x20)
        // No sequence number, payload size at offset 4
        // 4 (header) + 4 (size) + 10 (payload) = 18
        XCTAssertEqual(packet.count, 18)
    }

    func testEncodeAudioPacket_last() {
        let audio = Data(repeating: 0x55, count: 10)
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: audio,
            isLast: true
        )
        // Header byte 1: audioOnly=0010 | lastPacketNoSequence=0010 => 0x22
        XCTAssertEqual(packet[1], 0x22)
        // 4 (header) + 4 (size) + 10 (payload) = 18
        XCTAssertEqual(packet.count, 18)
    }

    // MARK: - Server Response Decoding

    func testDecodeServerMessage_withGzip() throws {
        let jsonPayload: [String: Any] = [
            "text": "hello world",
            "utterances": [
                ["text": "hello", "definite": true],
                ["text": "world", "definite": false]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)
        let compressed = try VolcProtocol.gzipCompress(jsonData)

        // Build a server response message
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: compressed)

        let result = try VolcProtocol.decodeServerMessage(message)
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.utterances.count, 2)
        XCTAssertEqual(result.utterances[0].text, "hello")
        XCTAssertEqual(result.utterances[0].definite, true)
        XCTAssertEqual(result.utterances[1].text, "world")
        XCTAssertEqual(result.utterances[1].definite, false)
    }

    func testDecodeServerResponse_preservesAsyncFinalFlag() throws {
        let jsonPayload: [String: Any] = [
            "result": [
                "text": "修正后的整句",
                "utterances": [
                    ["text": "修正后的整句", "definite": true]
                ]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .asyncFinal,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: jsonData)
        let response = try VolcProtocol.decodeServerResponse(message)
        XCTAssertEqual(response.header.flags, .asyncFinal)
        XCTAssertEqual(response.result.text, "修正后的整句")
        XCTAssertEqual(response.result.utterances.first?.text, "修正后的整句")
    }

    func testDecodeServerMessage_uncompressed() throws {
        let jsonPayload: [String: Any] = [
            "text": "test",
            "utterances": [] as [[String: Any]]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)

        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: jsonData)

        let result = try VolcProtocol.decodeServerMessage(message)
        XCTAssertEqual(result.text, "test")
        XCTAssertEqual(result.utterances.count, 0)
    }

    func testDecodeServerMessage_serverError() throws {
        let errorJson: [String: Any] = ["code": 1001, "message": "auth failed"]
        let jsonData = try JSONSerialization.data(withJSONObject: errorJson)

        let header = VolcHeader(
            messageType: .serverError,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: jsonData)

        XCTAssertThrowsError(try VolcProtocol.decodeServerMessage(message)) { error in
            guard case VolcProtocolError.serverError(let code, let msg) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(code, 1001)
            XCTAssertEqual(msg, "auth failed")
        }
    }

    // MARK: - Gzip Round-Trip

    func testGzipRoundTrip() throws {
        let original = "The quick brown fox jumps over the lazy dog. 重复数据重复数据重复数据".data(using: .utf8)!
        let compressed = try VolcProtocol.gzipCompress(original)
        let decompressed = try VolcProtocol.gzipDecompress(compressed)
        XCTAssertEqual(original, decompressed)
    }

    func testGzipRoundTrip_emptyData() throws {
        let empty = Data()
        let compressed = try VolcProtocol.gzipCompress(empty)
        XCTAssertEqual(compressed, Data())
        let decompressed = try VolcProtocol.gzipDecompress(empty)
        XCTAssertEqual(decompressed, Data())
    }

    func testGzipCompress_producesSmaller() throws {
        // Repetitive data should compress well
        let original = Data(repeating: 0x41, count: 10000)
        let compressed = try VolcProtocol.gzipCompress(original)
        XCTAssertLessThan(compressed.count, original.count)
    }
}
