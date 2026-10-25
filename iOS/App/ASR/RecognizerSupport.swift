import Foundation
import os
@preconcurrency import AVFoundation

// The cloud speech clients, their wire protocols and provider configs are
// compiled straight from the Mac sources (`Type4Me/ASR`, `Type4Me/Protocol`,
// see project.yml). The Mac declares these shared types in
// `Type4Me/ASR/SpeechRecognizer.swift` next to Mac-only session events;
// this file carries the part the clients use, with the same shapes.
// `L(zh, en)` comes from Shared/Localization.swift.

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    var boostingTableID: String?
    var contextHistoryLength: Int = 0
    var bypassProxy: Bool = false
    /// Mac cloud subscription only; always nil here.
    var cloudProxyURL: String?
    var customURLSessionConfiguration: URLSessionConfiguration?

    var urlSessionConfiguration: URLSessionConfiguration {
        customURLSessionConfiguration ?? .default
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enablePunc == rhs.enablePunc
            && lhs.hotwords == rhs.hotwords
            && lhs.boostingTableID == rhs.boostingTableID
            && lhs.contextHistoryLength == rhs.contextHistoryLength
            && lhs.bypassProxy == rhs.bypassProxy
            && lhs.cloudProxyURL == rhs.cloudProxyURL
            && lhs.customURLSessionConfiguration === rhs.customURLSessionConfiguration
    }
}

struct RecognitionTranscript: Sendable, Equatable {
    let confirmedSegments: [String]
    let partialText: String
    let authoritativeText: String
    let isFinal: Bool
    var emitTime: ContinuousClock.Instant = .now

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.confirmedSegments == rhs.confirmedSegments
            && lhs.partialText == rhs.partialText
            && lhs.authoritativeText == rhs.authoritativeText
            && lhs.isFinal == rhs.isFinal
    }

    static let empty = RecognitionTranscript(
        confirmedSegments: [],
        partialText: "",
        authoritativeText: "",
        isFinal: false
    )

    var composedText: String {
        let pieces = confirmedSegments + (partialText.isEmpty ? [] : [partialText])
        return pieces.joined()
    }

    var displayText: String {
        authoritativeText.isEmpty ? composedText : authoritativeText
    }
}

/// The events the speech clients emit; the Mac adds session-level ones.
enum RecognitionEvent: Sendable {
    case ready
    case sessionReady(generation: UInt64)
    case transcript(RecognitionTranscript)
    case error(Error)
    case completed
}

protocol SpeechRecognizer: Sendable {
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws
    func sendAudio(_ data: Data) async throws
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws
    func endAudio() async throws
    func disconnect() async
    var events: AsyncStream<RecognitionEvent> { get async }
}

extension SpeechRecognizer {
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
    }
}

/// Referenced by `LLMProviderConfig` in the shared `LLMProvider.swift`.
struct LLMConfig: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String
    let reasoningEffort: String?

    init(apiKey: String, model: String, baseURL: String = "", reasoningEffort: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.reasoningEffort = reasoningEffort
    }
}

/// The clients' verbose per-packet notes go to the unified log, not to the
/// user-facing diagnostics.
enum DebugFileLogger {
    private static let logger = Logger(subsystem: "com.type4me.ios", category: "ASR")

    static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}

/// Stable per-install user ID some providers ask for (Volcengine).
enum ASRIdentityStore {
    static func loadOrCreateUID() -> String { AppSettings.asrUID }
}
