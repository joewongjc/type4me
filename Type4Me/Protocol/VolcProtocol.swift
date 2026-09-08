import Foundation
import Compression

// MARK: - Result Types

struct VolcUtterance: Sendable, Equatable {
    let text: String
    let definite: Bool
}

struct VolcASRResult: Sendable, Equatable {
    let text: String
    let utterances: [VolcUtterance]
}

struct VolcServerResponse: Sendable, Equatable {
    let header: VolcHeader
    let result: VolcASRResult
}

// MARK: - Protocol Functions

enum VolcProtocol: Sendable {

    // MARK: - Auth Headers

    /// Builds the WebSocket handshake headers documented for both Volcengine
    /// consoles. New-console credentials use `X-Api-Key`; legacy-console
    /// credentials remain supported with the App ID + Access Token pair.
    static func authHeaders(
        authentication: VolcanoASRConfig.Authentication,
        resourceId: String,
        connectId: String
    ) -> [String: String] {
        var headers = [
            "X-Api-Resource-Id": resourceId,
            "X-Api-Connect-Id": connectId,
        ]
        switch authentication {
        case .apiKey(let apiKey):
            headers["X-Api-Key"] = apiKey
        case .legacy(let appKey, let accessKey):
            headers["X-Api-App-Key"] = appKey
            headers["X-Api-Access-Key"] = accessKey
        }
        return headers
    }

    // MARK: - Build Client Request JSON

    static func buildClientRequest(
        uid: String,
        format: String = "pcm",
        codec: String = "raw",
        rate: Int = 16000,
        bits: Int = 16,
        channel: Int = 1,
        showUtterances: Bool = true,
        resultType: String = "full",
        options: ASRRequestOptions = ASRRequestOptions()
    ) -> Data {
        var requestDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_punc": options.enablePunc,
            "enable_ddc": true,
            "enable_nonstream": true,
            "show_utterances": showUtterances,
            "result_type": resultType,
            "end_window_size": 3000,
            "force_to_speech_time": 0,
        ]

        var corpus: [String: Any] = [:]
        if let boostingTableID = sanitized(options.boostingTableID) {
            // Cloud boosting table: skip inline hotwords, use table ID only
            corpus["boosting_table_id"] = boostingTableID
        } else if let contextString = buildContextString(hotwords: options.hotwords) {
            // No cloud table: fall back to inline hotwords
            requestDict["context"] = contextString
        }
        if !corpus.isEmpty {
            requestDict["corpus"] = corpus
        }

        if options.contextHistoryLength > 0 {
            requestDict["context_history_length"] = options.contextHistoryLength
        }

        let payload: [String: Any] = [
            "user": ["uid": uid],
            "audio": [
                "format": format,
                "codec": codec,
                "rate": rate,
                "bits": bits,
                "channel": channel,
            ],
            "request": requestDict,
        ]
        // Force-try is safe here: dictionary of known-serializable types
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private static func buildContextString(hotwords: [String]) -> String? {
        var contextObject: [String: Any] = [:]

        let cleanedHotwords = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedHotwords.isEmpty {
            contextObject["hotwords"] = cleanedHotwords.map { ["word": $0, "scale": 5.0] as [String: Any] }
        }

        guard !contextObject.isEmpty,
              let contextData = try? JSONSerialization.data(withJSONObject: contextObject),
              let contextString = String(data: contextData, encoding: .utf8)
        else {
            return nil
        }
        return contextString
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    // MARK: - Encode Full Binary Message

    static func encodeMessage(
        header: VolcHeader,
        payload: Data,
        sequenceNumber: Int32? = nil
    ) -> Data {
        var message = header.encode()

        // Append sequence number if flagged
        if let seq = sequenceNumber {
            var seqBig = seq.bigEndian
            message.append(Data(bytes: &seqBig, count: 4))
        }

        // Append payload size (4 bytes big-endian) + payload
        var size = UInt32(payload.count).bigEndian
        message.append(Data(bytes: &size, count: 4))
        message.append(payload)

        return message
    }

    // MARK: - Encode Audio Packet

    static func encodeAudioPacket(
        audioData: Data,
        isLast: Bool
    ) -> Data {
        let flags: VolcMessageFlags = isLast ? .lastPacketNoSequence : .noSequence
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: flags,
            serialization: .none,
            compression: .none
        )
        return encodeMessage(header: header, payload: audioData)
    }

    // MARK: - Decode Server Message

    /// Best-effort extraction of the code and text from a server error frame.
    ///
    /// The documented layout is header, 4-byte error code, 4-byte body size,
    /// then the body, but no real error frame has ever been captured from this
    /// client to confirm it — issue #290 reached us as a server-side error the
    /// user only ever saw as a recording that stopped by itself. So rather than
    /// trusting one offset and throwing `invalidPayload` when it does not fit,
    /// this tries the plausible framings and returns whatever is readable.
    /// Surfacing the server's own words matters more than parsing them
    /// precisely; hiding them behind a parse failure is the actual defect.
    static func extractServerError(_ data: Data) -> (code: Int?, message: String?) {
        let headerBytes = Int((try? VolcHeader.decode(from: data))?.headerSize ?? 1) * 4
        guard data.count > headerBytes else { return (nil, nil) }
        let tail = Data(data[(data.startIndex + headerBytes)...])

        var code: Int?
        if tail.count >= 4 {
            let value = tail.prefix(4).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            // Volcengine error codes are 8-digit. Anything else is far more
            // likely to be a length prefix or the body itself, so it is
            // dropped rather than reported as a bogus code.
            if (10_000_000...99_999_999).contains(Int(value)) {
                code = Int(value)
            }
        }

        // Candidate bodies: the tail as-is, and with the code and size prefixes
        // peeled off, each also tried gzip-decompressed.
        var candidates: [Data] = []
        for skip in [0, 4, 8] where tail.count > skip {
            let slice = Data(tail[(tail.startIndex + skip)...])
            candidates.append(slice)
            if let inflated = try? gzipDecompress(slice) { candidates.append(inflated) }
        }

        for candidate in candidates {
            if let found = readableError(from: candidate) {
                // A code inside the body is unambiguous; the leading word is a
                // guess about framing, so it only fills in when the body has none.
                return (found.code ?? code, found.message)
            }
        }
        return (code, nil)
    }

    /// Pulls a code and a human-readable error out of a byte slice: a JSON
    /// object's fields if one is present, otherwise the raw text.
    ///
    /// Both shapes seen in this codebase are accepted — a body carrying its own
    /// `code`, and one carrying only text with the code in the framing.
    private static func readableError(from data: Data) -> (code: Int?, message: String?)? {
        let keys = ["error", "message", "msg", "error_msg"]

        func fromJSON(_ slice: Data) -> (code: Int?, message: String?)? {
            guard let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] else {
                return nil
            }
            let code = object["code"] as? Int
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return (code, value) }
            }
            return code.map { ($0, nil) }
        }

        if let found = fromJSON(data) { return found }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // The body may sit inside a larger slice when the framing guess is off.
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            let embedded = String(text[open...close])
            if let found = fromJSON(Data(embedded.utf8)) { return found }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject slices that are mostly control bytes: those are framing, not a
        // message. Decoding succeeded only because those bytes happen to be
        // valid UTF-8.
        let scalars = trimmed.unicodeScalars
        let printable = scalars.filter { $0.value >= 0x20 }.count
        guard printable * 4 >= scalars.count * 3 else { return nil }
        return (nil, String(trimmed.prefix(200)))
    }

    static func decodeServerResponse(_ data: Data) throws -> VolcServerResponse {
        let header = try VolcHeader.decode(from: data)

        // Handled before any length parsing: an error frame's framing is the
        // part we cannot verify, and a strict parse here would replace the
        // server's message with `invalidPayload`.
        if header.messageType == .serverError {
            let extracted = extractServerError(data)
            throw VolcProtocolError.serverError(code: extracted.code, message: extracted.message)
        }

        let headerBytes = Int(header.headerSize) * 4
        var offset = headerBytes

        // Skip sequence number if present
        if header.flags == .positiveSequence || header.flags == .negativeSequenceLast {
            offset += 4
        }

        guard data.count >= offset + 4 else {
            throw VolcProtocolError.invalidPayload
        }

        // Read payload size
        let sizeBytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        let payloadSize = Int(UInt32(bigEndian: sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4

        guard data.count >= offset + payloadSize else {
            throw VolcProtocolError.invalidPayload
        }

        var payload = data[data.startIndex + offset ..< data.startIndex + offset + payloadSize]

        // Decompress if needed
        if header.compression == .gzip {
            payload = try gzipDecompress(Data(payload))
        }

        // Parse JSON
        guard header.serialization == .json else {
            throw VolcProtocolError.invalidPayload
        }

        guard let json = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw VolcProtocolError.invalidPayload
        }

        // Response format: {"result": {"text": "...", "utterances": [...]}, "audio_info": {...}}
        let resultObj = json["result"] as? [String: Any]
        let text = resultObj?["text"] as? String ?? json["text"] as? String ?? ""
        var utterances: [VolcUtterance] = []

        let uttsSource = resultObj?["utterances"] as? [[String: Any]]
            ?? json["utterances"] as? [[String: Any]]
        if let utts = uttsSource {
            utterances = utts.map { u in
                VolcUtterance(
                    text: u["text"] as? String ?? "",
                    definite: u["definite"] as? Bool ?? false
                )
            }
        }

        return VolcServerResponse(
            header: header,
            result: VolcASRResult(text: text, utterances: utterances)
        )
    }

    static func decodeServerMessage(_ data: Data) throws -> VolcASRResult {
        try decodeServerResponse(data).result
    }

    // MARK: - Gzip

    private static func processStream(
        operation: compression_stream_operation,
        source: Data
    ) -> Data? {
        let pageSize = 16384
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pageSize)
        defer { dstBuffer.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        let initStatus = compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        return source.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcPointer.baseAddress else { return nil }

            streamPtr.pointee.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
            streamPtr.pointee.src_size = source.count

            var output = Data()

            repeat {
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = pageSize

                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                let produced = pageSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                if status == COMPRESSION_STATUS_END {
                    break
                }
                if status == COMPRESSION_STATUS_ERROR {
                    return nil
                }
            } while true

            return output
        }
    }

    static func gzipCompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard let result = processStream(operation: COMPRESSION_STREAM_ENCODE, source: data) else {
            throw VolcProtocolError.compressionFailed
        }
        return result
    }

    static func gzipDecompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard let result = processStream(operation: COMPRESSION_STREAM_DECODE, source: data) else {
            throw VolcProtocolError.decompressionFailed
        }
        return result
    }
}
