import Foundation

// Synchronous batch endpoints used when a provider's recognition mode is `.batch`.

// MARK: - Alibaba Cloud Bailian

/// DashScope multimodal-generation endpoint. The OpenAI-compatible chat endpoint rejects
/// qwen-audio-3.1-asr-flash, so the native DashScope format is used.
struct BailianBatchTranscriber: BatchASRTranscriber {
    static let defaultHost = "dashscope.aliyuncs.com"
    static let path = "/api/v1/services/aigc/multimodal-generation/generation"

    let providerName = L("阿里云百炼", "Alibaba Cloud Bailian")
    /// Base64 uploads are capped at 10MB, about 3.9 minutes of 16kHz mono WAV.
    let maxDuration: TimeInterval? = 3.5 * 60

    /// Reuses the host of a custom WebSocket base URL (e.g. the international region).
    static func endpoint(for config: BailianASRConfig) -> URL {
        let host = URL(string: config.baseURL)?.host ?? defaultHost
        return URL(string: "https://\(host)\(path)")!
    }

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest {
        guard let config = config as? BailianASRConfig else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }

        let wav = WAVEncoder.encode(pcmData: pcmData)
        var parameters: [String: Any] = [
            "format": "wav",
            "sample_rate": 16_000,
        ]
        if let vocabularyID = Self.nonEmpty(options.boostingTableID) ?? Self.nonEmpty(config.vocabularyId) {
            parameters["vocabulary_id"] = vocabularyID
        }
        if let languageHint = Self.nonEmpty(config.languageHint) {
            parameters["language_hints"] = [languageHint]
        }

        let body: [String: Any] = [
            "model": config.batchModel,
            "input": [
                "messages": [[
                    "role": "user",
                    "content": [[
                        "type": "input_audio",
                        "input_audio": ["data": "data:audio/wav;base64,\(wav.base64EncodedString())"],
                    ]],
                ]],
            ],
            "parameters": parameters,
        ]

        var request = URLRequest(url: Self.endpoint(for: config))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = BatchASRHTTP.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any]
        else {
            throw BatchASRError.invalidResponse(provider: providerName)
        }

        if let text = output["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let choices = output["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let text = message["content"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let sentence = output["sentence"] as? [String: Any], let text = sentence["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw BatchASRError.invalidResponse(provider: providerName)
    }

    /// DashScope answers silent audio with HTTP 400 `ASR_RESPONSE_HAVE_NO_WORDS`.
    func isNoSpeechResponse(statusCode: Int, data: Data) -> Bool {
        statusCode == 400 && String(decoding: data, as: UTF8.self).contains("ASR_RESPONSE_HAVE_NO_WORDS")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Gemini

/// `models/{model}:generateContent` with the recording sent inline.
struct GeminiBatchTranscriber: BatchASRTranscriber {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta/"

    let providerName = "Gemini"
    static let normalFinishReasons: Set<String> = ["STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED"]
    /// Inline requests are capped at 20MB; base64 WAV reaches that at about 7.8 minutes.
    let maxDuration: TimeInterval? = 7 * 60

    static func endpoint(model: String) -> URL? {
        URL(string: baseURL + GeminiTranscribeProtocol.qualifiedModelName(model) + ":generateContent")
    }

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest {
        guard let config = config as? GeminiASRConfig,
              let url = Self.endpoint(model: config.batchModel.isEmpty ? GeminiASRConfig.defaultBatchModel : config.batchModel)
        else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }

        var transcriptionConfig: [String: Any] = ["mode": config.mode.rawValue]
        let language = config.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty, language.lowercased() != "auto" {
            transcriptionConfig["languageCodes"] = [language]
        }
        let vocabulary = GeminiTranscribeProtocol.sanitizeHotwords(options.hotwords)
        if !vocabulary.isEmpty {
            transcriptionConfig["customVocabulary"] = vocabulary
        }

        let wav = WAVEncoder.encode(pcmData: pcmData)
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [[
                    "inlineData": [
                        "mimeType": "audio/wav",
                        "data": wav.base64EncodedString(),
                    ],
                ]],
            ]],
            "generationConfig": [
                "audioTranscriptionConfig": transcriptionConfig,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = BatchASRHTTP.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BatchASRError.invalidResponse(provider: providerName)
        }
        if let feedback = root["promptFeedback"] as? [String: Any],
           let blockReason = feedback["blockReason"] as? String {
            throw BatchASRError.blocked(provider: providerName, reason: blockReason)
        }
        guard let candidates = root["candidates"] as? [[String: Any]], let candidate = candidates.first else {
            throw BatchASRError.invalidResponse(provider: providerName)
        }
        // Only a normal stop without content means silence; SAFETY, RECITATION, etc. are failures.
        let finishReason = candidate["finishReason"] as? String
        if let finishReason, !Self.normalFinishReasons.contains(finishReason) {
            throw BatchASRError.blocked(provider: providerName, reason: finishReason)
        }
        guard let content = candidate["content"] as? [String: Any] else { return "" }
        let parts = content["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRHotwordLeakSanitizer.sanitize(text, hotwords: options.hotwords)
    }
}

// MARK: - ElevenLabs

/// `POST /v1/speech-to-text`, uploading raw 16kHz PCM to skip server-side decoding.
struct ElevenLabsBatchTranscriber: BatchASRTranscriber {
    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    let providerName = "ElevenLabs"
    let maxDuration: TimeInterval? = nil

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest {
        guard let config = config as? ElevenLabsASRConfig else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }

        var form = MultipartFormBody()
        form.append(name: "model_id", value: config.batchModel)
        form.append(name: "file_format", value: "pcm_s16le_16")
        form.append(name: "tag_audio_events", value: "false")
        form.append(name: "timestamps_granularity", value: "none")
        form.append(name: "no_verbatim", value: "true")
        if !config.language.isEmpty {
            form.append(name: "language_code", value: config.language)
        }
        for term in Self.keyterms(from: options.hotwords) {
            form.append(name: "keyterms", value: term)
        }
        form.append(name: "file", filename: "audio.pcm", mimeType: "application/octet-stream", fileData: pcmData)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = BatchASRHTTP.requestTimeout
        request.httpBody = form.finalized()
        return request
    }

    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String
        else {
            throw BatchASRError.invalidResponse(provider: providerName)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same limits as the realtime client: at most 50 terms of 20 characters or fewer.
    static func keyterms(from hotwords: [String]) -> [String] {
        Array(
            hotwords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 20 }
                .prefix(50)
        )
    }
}

// MARK: - Grok

/// `POST /v1/stt` with raw PCM; the file part must come after every option field.
struct GrokBatchTranscriber: BatchASRTranscriber {
    static let endpoint = URL(string: "https://api.x.ai/v1/stt")!

    let providerName = "Grok"
    let maxDuration: TimeInterval? = nil

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest {
        guard let config = config as? GrokASRConfig else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }

        var form = MultipartFormBody()
        form.append(name: "model", value: GrokASRConfig.model)
        form.append(name: "audio_format", value: "pcm")
        form.append(name: "sample_rate", value: "16000")
        form.append(name: "filler_words", value: "false")
        if !config.language.isEmpty {
            form.append(name: "language", value: config.language)
        }
        for term in Self.keyterms(from: options.hotwords) {
            form.append(name: "keyterm", value: term)
        }
        form.append(name: "file", filename: "audio.pcm", mimeType: "application/octet-stream", fileData: pcmData)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = BatchASRHTTP.requestTimeout
        request.httpBody = form.finalized()
        return request
    }

    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String
        else {
            throw BatchASRError.invalidResponse(provider: providerName)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Up to 100 terms, each at most 50 characters.
    static func keyterms(from hotwords: [String]) -> [String] {
        Array(
            hotwords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 50 }
                .prefix(100)
        )
    }
}
