import Foundation

/// Transcriber for Tencent Cloud asynchronous recording file recognition (CreateRecTask + DescribeTaskStatus).
struct TencentRecTaskTranscriber: BatchASRTranscriber {

    let providerName = L("腾讯云", "Tencent Cloud")
    /// CreateRecTask rejects inline audio over 5,242,880 raw bytes, about 163 s of 16 kHz WAV.
    let maxDuration: TimeInterval? = 150
    let suggestsRealtimeFallback = true

    /// Polling rhythm: fast at first for short dictation, then back off to 1s.
    static let pollIntervals: [Duration] = [.milliseconds(300), .milliseconds(500), .milliseconds(800)]
    static let maxPollInterval: Duration = .seconds(1)
    static let pollDeadline: Duration = .seconds(90)

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest {
        guard let config = config as? TencentASRConfig else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }

        let wav = WAVEncoder.encode(pcmData: pcmData)
        var body: [String: Any] = [
            "EngineModelType": TencentASRConfig.engineModelType,
            "ChannelNum": 1,
            "ResTextFormat": 0,
            "SourceType": 1,
            "Data": wav.base64EncodedString(),
            "DataLen": wav.count,
            "ConvertNumMode": 1,
            "FilterDirty": 0,
            "FilterModal": 0,
            "FilterPunc": 0,
        ]

        if let hotwords = TencentHotwords.formatList(from: options.hotwords) {
            body["HotwordList"] = hotwords
        }

        let payload = try JSONSerialization.data(withJSONObject: body)
        let timestamp = Int(Date().timeIntervalSince1970)

        return TencentCloudSigner.signedAPIRequest(
            action: "CreateRecTask",
            payload: payload,
            secretId: config.secretId,
            secretKey: config.secretKey,
            timestamp: timestamp
        )
    }

    func transcribe(
        pcmData: Data,
        config: any ASRProviderConfig,
        options: ASRRequestOptions,
        session: URLSession
    ) async throws -> String {
        guard let config = config as? TencentASRConfig else {
            throw BatchASRError.invalidConfig(provider: providerName)
        }

        // 1. Submit task
        let createReq = try makeRequest(pcmData: pcmData, config: config, options: options)
        let (createData, createResp) = try await session.data(for: createReq)

        guard let httpResp = createResp as? HTTPURLResponse else {
            throw BatchASRError.requestFailed(provider: providerName, code: 0, message: nil)
        }
        guard httpResp.statusCode == 200 else {
            throw BatchASRError.requestFailed(
                provider: providerName,
                code: httpResp.statusCode,
                message: BatchASRHTTP.errorMessage(from: createData)
            )
        }

        if let err = Self.apiError(from: createData) {
            throw TencentASRError.taskFailed(code: err.code, message: err.message)
        }

        guard let root = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let respObj = root["Response"] as? [String: Any],
              let dataObj = respObj["Data"] as? [String: Any],
              let taskId = dataObj["TaskId"] as? Int
        else {
            throw BatchASRError.invalidResponse(provider: providerName)
        }

        // 2. Poll for status
        let startTime = ContinuousClock.now
        var pollCount = 0

        while !Task.isCancelled {
            if ContinuousClock.now - startTime > Self.pollDeadline {
                throw TencentASRError.taskTimedOut
            }

            let interval: Duration
            if pollCount < Self.pollIntervals.count {
                interval = Self.pollIntervals[pollCount]
            } else {
                interval = Self.maxPollInterval
            }
            pollCount += 1

            try await Task.sleep(for: interval)

            let descBody = ["TaskId": taskId]
            let descPayload = try JSONSerialization.data(withJSONObject: descBody)
            let descReq = TencentCloudSigner.signedAPIRequest(
                action: "DescribeTaskStatus",
                payload: descPayload,
                secretId: config.secretId,
                secretKey: config.secretKey,
                timestamp: Int(Date().timeIntervalSince1970)
            )

            let (descData, descResp) = try await session.data(for: descReq)
            guard let descHttp = descResp as? HTTPURLResponse, descHttp.statusCode == 200 else {
                continue
            }

            if let err = Self.apiError(from: descData) {
                throw TencentASRError.taskFailed(code: err.code, message: err.message)
            }

            guard let descRoot = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                  let descRespObj = descRoot["Response"] as? [String: Any],
                  let descDataObj = descRespObj["Data"] as? [String: Any],
                  let status = descDataObj["Status"] as? Int
            else {
                continue
            }

            switch status {
            case 0, 1:
                // 0: waiting, 1: in progress -> keep polling
                continue
            case 2:
                // 2: success
                let result = descDataObj["Result"] as? String ?? ""
                return Self.cleanResultText(result)
            case 3:
                // 3: failed
                let errorMsg = (descDataObj["ErrorMsg"] as? String) ?? ""
                throw TencentASRError.taskFailed(code: "FailedOperation", message: errorMsg)
            default:
                continue
            }
        }

        throw CancellationError()
    }

    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resp = json["Response"] as? [String: Any],
           let d = resp["Data"] as? [String: Any],
           let result = d["Result"] as? String {
            return Self.cleanResultText(result)
        }
        let raw = String(decoding: data, as: UTF8.self)
        return Self.cleanResultText(raw)
    }

    // MARK: - Helpers

    static func apiError(from data: Data) -> (code: String, message: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["Response"] as? [String: Any],
              let err = resp["Error"] as? [String: Any],
              let code = err["Code"] as? String
        else {
            return nil
        }
        let message = err["Message"] as? String ?? ""
        return (code: code, message: message)
    }

    static func cleanResultText(_ result: String) -> String {
        let lines = result.components(separatedBy: .newlines)
        let regex = try? NSRegularExpression(pattern: #"^\s*\[[^\]]*\]\s*"#)

        var cleanedLines: [String] = []
        for line in lines {
            let stripped = regex?.stringByReplacingMatches(
                in: line,
                range: NSRange(line.startIndex..., in: line),
                withTemplate: ""
            ) ?? line

            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                cleanedLines.append(trimmed)
            }
        }

        guard !cleanedLines.isEmpty else { return "" }
        return cleanedLines.joined()
    }
}
