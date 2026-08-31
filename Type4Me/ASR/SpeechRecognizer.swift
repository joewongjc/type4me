import Foundation
@preconcurrency import AVFoundation
import Type4MeReviseCore

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    var boostingTableID: String?
    var contextHistoryLength: Int = 20
    var bypassProxy: Bool = false
    /// When set, ASR clients connect to this URL instead of their default endpoint.
    var cloudProxyURL: String?
    var customURLSessionConfiguration: URLSessionConfiguration?

    var urlSessionConfiguration: URLSessionConfiguration {
        if let custom = customURLSessionConfiguration {
            return custom
        }
        let config = URLSessionConfiguration.default
        if bypassProxy {
            config.connectionProxyDictionary = [:]
        }
        return config
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

enum ProxyBypassMode: String {
    case off, all, asr, llm

    static var current: ProxyBypassMode {
        ProxyBypassMode(rawValue: UserDefaults.standard.string(forKey: "tf_bypassProxy") ?? "off") ?? .off
    }

    var bypassASR: Bool { self == .all || self == .asr }
    var bypassLLM: Bool { self == .all || self == .llm }
}

struct RecognitionTranscript: Sendable, Equatable {
    let confirmedSegments: [String]
    let partialText: String
    let authoritativeText: String
    let isFinal: Bool
    /// Monotonic timestamp when the ASR client emitted this transcript.
    /// Used for pipeline latency diagnostics; excluded from Equatable.
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

enum InjectionOutcome: Sendable, Equatable {
    case inserted
    /// Cmd+V was sent to an AX-opaque editor, but insertion cannot be proven.
    /// The dictated result intentionally remains in the clipboard.
    case pasteAttemptedClipboardRetained
    case copiedToClipboard
    case notInserted
    case discarded

    var completionMessage: String {
        switch self {
        case .inserted:
            return L("已完成", "Done")
        case .pasteAttemptedClipboardRetained:
            return L(
                "已尝试输入，文本已保留到剪贴板",
                "Paste attempted; text kept in clipboard"
            )
        case .copiedToClipboard:
            return L("已粘贴到剪贴板", "Copied to clipboard")
        case .notInserted:
            return L("未找到可输入的位置", "No editable field found")
        case .discarded:
            return L("已取消", "Cancelled")
        }
    }
}

enum RecognitionEvent: Sendable {
    case ready
    case transcript(RecognitionTranscript)
    case error(Error)
    case completed
    case processingResult(text: String)
    case processingLabelOverride(String)
    case recoveryStarted(text: String, message: String)
    case recoveryPrompt(text: String, message: String)
    case recoverySucceeded(text: String, message: String)
    case recoveryFailed(text: String, message: String)
    case recoveryInterrupted(text: String, message: String)
    case finalized(text: String, injection: InjectionOutcome)
    /// Mac Action mode: action result to surface in the floating bar with
    /// status-specific icon and color, holding for ~3 seconds.
    case macActionResult(message: String, status: MacActionResultStatus)
    /// Selection ask mode: show a separate answer panel and stream Markdown into it.
    case selectionAskStarted(
        requestID: UUID,
        question: String,
        selectedText: String,
        contextWasTruncated: Bool
    )
    case selectionAskAnswerDelta(requestID: UUID, delta: String)
    case selectionAskAnswerCompleted(requestID: UUID)
    case selectionAskAnswerFailed(requestID: UUID, message: String)
    case reviseProcessing
    case reviseCompleted(text: String, message: String, undoTicketID: UUID?)
    case reviseFailed(ReviseFailure)
    case reviseCancelled
    case reviseUndone(text: String)
}

struct LLMConfig: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String

    init(apiKey: String, model: String, baseURL: String = "") {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }
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
