import Foundation

// MARK: - Wire Model & Decoder

struct TencentSentenceUpdate: Equatable {
    let id: Int
    let text: String
    let isFinal: Bool
}

struct TencentRealtimeMessage: Equatable {
    let code: Int
    let message: String?
    let voiceId: String?
    let updates: [TencentSentenceUpdate]
    let isFinal: Bool

    static func decode(from data: Data) -> TencentRealtimeMessage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(from: root)
    }

    static func decode(from root: [String: Any]) -> TencentRealtimeMessage? {
        guard let code = root["code"] as? Int else { return nil }
        let message = root["message"] as? String
        let voiceId = root["voice_id"] as? String
        let isFinal = (root["final"] as? Int == 1)

        var updates: [TencentSentenceUpdate] = []

        if let result = root["result"] as? [String: Any] {
            let sliceType = result["slice_type"] as? Int ?? 0
            let index = result["index"] as? Int ?? 0
            let voiceText = (result["voice_text_str"] as? String) ?? ""
            updates = [
                TencentSentenceUpdate(id: index, text: voiceText, isFinal: sliceType == 2)
            ]
        } else if let sentences = root["sentences"] {
            if let array = sentences as? [[String: Any]] {
                updates = array.map { s in
                    let id = s["sentence_id"] as? Int ?? 0
                    let text = (s["sentence"] as? String) ?? ""
                    let type = s["sentence_type"] as? Int ?? 0
                    return TencentSentenceUpdate(id: id, text: text, isFinal: type == 1)
                }
            } else if let single = sentences as? [String: Any] {
                let id = single["sentence_id"] as? Int ?? 0
                let text = (single["sentence"] as? String) ?? ""
                let type = single["sentence_type"] as? Int ?? 0
                updates = [TencentSentenceUpdate(id: id, text: text, isFinal: type == 1)]
            }
        }

        return TencentRealtimeMessage(
            code: code,
            message: message,
            voiceId: voiceId,
            updates: updates,
            isFinal: isFinal
        )
    }
}

// MARK: - State Machine

struct TencentTranscriptState {
    private var sentences: [Int: String] = [:]
    private var confirmedIDs: Set<Int> = []
    private var isCompleted = false

    mutating func apply(_ update: TencentSentenceUpdate) {
        guard !confirmedIDs.contains(update.id) else {
            return
        }
        sentences[update.id] = update.text
        if update.isFinal {
            confirmedIDs.insert(update.id)
        }
    }

    mutating func markFinal() {
        isCompleted = true
        for id in sentences.keys {
            confirmedIDs.insert(id)
        }
    }

    var transcript: RecognitionTranscript {
        let sortedIDs = sentences.keys.sorted()
        var confirmed: [String] = []
        var partial: [String] = []

        for id in sortedIDs {
            let text = sentences[id] ?? ""
            guard !text.isEmpty else { continue }
            if confirmedIDs.contains(id) {
                confirmed.append(text)
            } else {
                partial.append(text)
            }
        }

        let partialText = partial.joined()
        let authoritativeText = (confirmed + (isCompleted ? [] : partial)).joined()

        return RecognitionTranscript(
            confirmedSegments: confirmed,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isCompleted
        )
    }
}

// MARK: - Errors

enum TencentASRError: Error, LocalizedError, Equatable {
    case invalidURL
    case handshakeFailed(code: Int, message: String)
    case server(code: Int, message: String)
    case taskFailed(code: String, message: String)
    case taskTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("无效的腾讯云请求地址", "Invalid Tencent Cloud request URL")
        case .handshakeFailed(let code, let message):
            return Self.mapServerCode(code: code, rawMessage: message)
        case .server(let code, let message):
            return Self.mapServerCode(code: code, rawMessage: message)
        case .taskFailed(let code, let message):
            return Self.mapAPICode(code: code, message: message)
        case .taskTimedOut:
            return L("腾讯云识别任务超时，请重试或切换为实时流式", "The Tencent Cloud task timed out. Retry or switch to real-time mode.")
        }
    }

    static func mapServerCode(code: Int, rawMessage: String) -> String {
        switch code {
        case 4002:
            return L("腾讯云 SecretId 或 SecretKey 无效 (\(code))", "Invalid Tencent Cloud SecretId or SecretKey (\(code))")
        case 4003:
            return L("该 AppID 未开通语音识别服务，请在控制台开通 (\(code))", "ASR is not enabled for this AppID. Enable it in the console. (\(code))")
        case 4004:
            return L("腾讯云语音识别资源包已用完，请购买资源包或开启后付费 (\(code))", "ASR resource pack exhausted. Buy a pack or enable pay-as-you-go. (\(code))")
        case 4005:
            return L("腾讯云账号已欠费，请充值后重试 (\(code))", "The Tencent Cloud account is in arrears. Top up and retry. (\(code))")
        case 4006:
            return L("腾讯云并发路数已达上限，请稍后再试 (\(code))", "Concurrency limit reached. Try again later. (\(code))")
        case 6001:
            return L("当前网络被识别为海外，请关闭海外代理，或在代理设置中为 ASR 绕过代理 (\(code))", "Detected as an overseas call. Disable overseas proxies or bypass the proxy for ASR. (\(code))")
        case 5000...5002:
            return L("腾讯云服务暂时不可用，请重试 (\(code))", "Tencent Cloud is temporarily unavailable. Retry. (\(code))")
        default:
            if !rawMessage.isEmpty {
                return "\(rawMessage) (\(code))"
            }
            return L("腾讯云识别服务异常 (\(code))", "Tencent Cloud ASR service error (\(code))")
        }
    }

    static func mapAPICode(code: String, message: String) -> String {
        if code.hasPrefix("AuthFailure") {
            if code == "AuthFailure.SignatureExpire" {
                return L("腾讯云签名过期，请检查系统时间是否正确 (\(code))", "Tencent Cloud signature expired. Please check your system clock. (\(code))")
            }
            return L("腾讯云 SecretId 或 SecretKey 无效 (\(code))", "Invalid Tencent Cloud SecretId or SecretKey (\(code))")
        }
        if code.hasPrefix("UnauthorizedOperation") {
            return L("子账号权限不足，请在访问管理中授权语音识别服务 (\(code))", "Insufficient sub-account permissions. Please grant ASR permissions in CAM. (\(code))")
        }
        if code == "FailedOperation.NoSuchTask" {
            return L("未找到该腾讯云识别任务或已过期 (\(code))", "Tencent Cloud task not found or expired. (\(code))")
        }
        if code.hasPrefix("FailedOperation") {
            return "\(message.isEmpty ? L("腾讯云服务操作失败", "Tencent Cloud operation failed") : message) (\(code))"
        }
        if code.hasPrefix("InvalidParameter") || code == "MissingParameter" {
            return "\(message.isEmpty ? L("请求参数错误", "Invalid request parameter") : message) (\(code))"
        }
        if code.hasPrefix("RequestLimitExceeded") {
            return L("腾讯云请求过于频繁，请稍后再试 (\(code))", "Tencent Cloud request limit exceeded. Try again later. (\(code))")
        }
        if code.hasPrefix("InternalError") {
            return L("腾讯云服务暂时不可用，请重试 (\(code))", "Tencent Cloud is temporarily unavailable. Retry. (\(code))")
        }
        return "腾讯云 \(code)：\(message)"
    }
}

// MARK: - Hotwords Formatter

enum TencentHotwords {
    static let maxHotwords = 128
    static let maxHotwordLength = 30
    static let maxHotwordHanCharacters = 10
    static let hotwordWeight = 10

    static func formatList(from hotwords: [String]) -> String? {
        var seen = Set<String>()
        var validTerms: [String] = []

        for h in hotwords {
            let term = h.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            // Skip terms containing whitespace, commas, or pipes
            if term.contains(" ") || term.contains("\t") || term.contains(",") || term.contains("，") || term.contains("|") {
                continue
            }
            // Check character limits
            guard term.count <= maxHotwordLength else { continue }

            var hanCount = 0
            for scalar in term.unicodeScalars {
                if isHan(scalar) {
                    hanCount += 1
                }
            }
            guard hanCount <= maxHotwordHanCharacters else { continue }

            let lower = term.lowercased()
            if seen.insert(lower).inserted {
                validTerms.append("\(term)|\(hotwordWeight)")
                if validTerms.count >= maxHotwords {
                    break
                }
            }
        }

        guard !validTerms.isEmpty else { return nil }
        return validTerms.joined(separator: ",")
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) ||
               (v >= 0x3400 && v <= 0x4DBF) ||
               (v >= 0x20000 && v <= 0x2A6DF) ||
               (v >= 0xF900 && v <= 0xFAFF)
    }
}
