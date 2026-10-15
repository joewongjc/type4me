import Foundation

enum CustomASRError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidHeader(line: Int)
    case invalidTemplate
    case missingAudioPlaceholder(String)
    case resultFieldNotFound(path: String, preview: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L("请求地址无效，需要以 http:// 或 https:// 开头",
                     "Invalid endpoint URL; it must start with http:// or https://")
        case .invalidHeader(let line):
            return L("请求头第 \(line) 行格式不对，应为「名称: 值」",
                     "Header line \(line) must look like \"Name: value\"")
        case .invalidTemplate:
            return L(#"请求体模板必须是 JSON 对象，例如 {"audio": "{{audio_base64}}"}"#,
                     #"The body template must be a JSON object, e.g. {"audio": "{{audio_base64}}"}"#)
        case .missingAudioPlaceholder(let placeholder):
            return L("请求体模板里没有 \(placeholder)，录音无处可放",
                     "The body template has no \(placeholder), so there is nowhere to put the audio")
        case .resultFieldNotFound(let path, let preview):
            return L("响应里找不到结果字段 \(path)：\(preview)",
                     "Result field \(path) not found in the response: \(preview)")
        }
    }
}

/// Builds the user-described request for `CustomASRConfig` and reads the transcript back.
struct CustomHTTPBatchTranscriber: BatchASRTranscriber {
    static let apiKeyPlaceholder = "{{api_key}}"
    static let audioBase64Placeholder = "{{audio_base64}}"
    static let audioFilePlaceholder = "{{audio_file}}"
    /// Upstream error codes that only mean "no speech", e.g. Volcano 20000003 relayed by a gateway as HTTP 502.
    static let noSpeechMarkers = ["20000003", "ASR_RESPONSE_HAVE_NO_WORDS"]

    let providerName = L("自定义识别", "Custom ASR")
    let maxDuration: TimeInterval? = nil

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest {
        guard let config = config as? CustomASRConfig else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }
        guard let url = URL(string: config.endpointURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw CustomASRError.invalidEndpoint
        }
        let headers = try Self.parseHeaders(config.headers, apiKey: config.apiKey)
        let template = try Self.parseTemplate(config.bodyTemplate)
        let wav = WAVEncoder.encode(pcmData: pcmData)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BatchASRHTTP.requestTimeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        switch config.uploadFormat {
        case .json:
            guard Self.contains(Self.audioBase64Placeholder, in: template) else {
                throw CustomASRError.missingAudioPlaceholder(Self.audioBase64Placeholder)
            }
            let body = Self.substitute(template, [
                Self.apiKeyPlaceholder: config.apiKey,
                Self.audioBase64Placeholder: wav.base64EncodedString(),
            ])
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        case .multipart:
            guard template.values.contains(where: { ($0 as? String) == Self.audioFilePlaceholder }) else {
                throw CustomASRError.missingAudioPlaceholder(Self.audioFilePlaceholder)
            }
            let boundary = "Type4Me-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartBody(
                fields: template, apiKey: config.apiKey, wav: wav, boundary: boundary
            )
        }
        return request
    }

    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String {
        try parseTranscript(from: data, resultPath: CustomASRConfig.defaultResultPath)
    }

    func parseTranscript(from data: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> String {
        let path = (config as? CustomASRConfig)?.resultPath ?? CustomASRConfig.defaultResultPath
        return try parseTranscript(from: data, resultPath: path)
    }

    func isNoSpeechResponse(statusCode: Int, data: Data) -> Bool {
        let body = String(decoding: data, as: UTF8.self)
        return Self.noSpeechMarkers.contains { body.contains($0) }
    }

    // MARK: - Request Building

    /// One `Name: value` per line. With no header lines and an API key, sends `Authorization: Bearer <key>`.
    static func parseHeaders(_ text: String, apiKey: String) throws -> [(String, String)] {
        var headers: [(String, String)] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw CustomASRError.invalidHeader(line: index + 1)
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                throw CustomASRError.invalidHeader(line: index + 1)
            }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: apiKeyPlaceholder, with: apiKey)
            headers.append((name, value))
        }
        if headers.isEmpty, !apiKey.isEmpty {
            headers.append(("Authorization", "Bearer \(apiKey)"))
        }
        return headers
    }

    /// Accepts curly quotes from rich-text sources when the template is otherwise invalid JSON.
    static func parseTemplate(_ text: String) throws -> [String: Any] {
        let normalized = text
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        for candidate in [text, normalized] {
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        throw CustomASRError.invalidTemplate
    }

    static func contains(_ placeholder: String, in value: Any) -> Bool {
        switch value {
        case let string as String: return string.contains(placeholder)
        case let dict as [String: Any]: return dict.values.contains { contains(placeholder, in: $0) }
        case let array as [Any]: return array.contains { contains(placeholder, in: $0) }
        default: return false
        }
    }

    static func substitute(_ value: [String: Any], _ replacements: [String: String]) -> [String: Any] {
        value.mapValues { substituteValue($0, replacements) }
    }

    private static func substituteValue(_ value: Any, _ replacements: [String: String]) -> Any {
        switch value {
        case let string as String:
            return replacements.reduce(string) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        case let dict as [String: Any]:
            return substitute(dict, replacements)
        case let array as [Any]:
            return array.map { substituteValue($0, replacements) }
        default:
            return value
        }
    }

    static func multipartBody(fields: [String: Any], apiKey: String, wav: Data, boundary: String) -> Data {
        var body = Data()
        for key in fields.keys.sorted() {
            body.append(Data("--\(boundary)\r\n".utf8))
            let value = fields[key]!
            if (value as? String) == audioFilePlaceholder {
                body.append(Data("Content-Disposition: form-data; name=\"\(key)\"; filename=\"audio.wav\"\r\n".utf8))
                body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
                body.append(wav)
            } else {
                let text = formValue(substituteValue(value, [apiKeyPlaceholder: apiKey]))
                body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                body.append(Data(text.utf8))
            }
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func formValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    // MARK: - Response Parsing

    func parseTranscript(from data: Data, resultPath: String) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let text = Self.value(at: resultPath, in: root) as? String
        else {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw CustomASRError.resultFieldNotFound(path: resultPath, preview: preview)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves dotted paths with array indexes, e.g. `results[0].alternatives[0].transcript`.
    static func value(at path: String, in root: Any) -> Any? {
        var current: Any? = root
        for component in path.split(separator: ".") {
            var name = component
            var indexes: [Int] = []
            while name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
                guard let index = Int(name[name.index(after: open)..<name.index(before: name.endIndex)]) else {
                    return nil
                }
                indexes.insert(index, at: 0)
                name = name[..<open]
            }
            if !name.isEmpty {
                guard let dict = current as? [String: Any] else { return nil }
                current = dict[String(name)]
            }
            for index in indexes {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }
}
