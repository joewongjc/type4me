import Foundation
@preconcurrency import AVFoundation

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    var boostingTableID: String?
    var contextHistoryLength: Int = 20
    var bypassProxy: Bool = false
    /// When set, ASR clients connect to this URL instead of their default endpoint.
    var cloudProxyURL: String?
    var urlSessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        if bypassProxy {
            config.connectionProxyDictionary = [:]
        }
        return config
    }

    /// Shared URLSession for ASR WebSocket connections.
    /// Reusing one session across recordings keeps the TCP connection pool warm,
    /// saving ~150-300ms on each subsequent connect (skips TCP + TLS handshake).
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// The URLSession to use for ASR connections. Returns the shared session
    /// unless bypassProxy is set (which needs a custom configuration).
    var resolvedSession: URLSession {
        bypassProxy ? URLSession(configuration: urlSessionConfiguration) : Self.sharedSession
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
    case copiedToClipboard

    var completionMessage: String {
        switch self {
        case .inserted:
            return L("已完成", "Done")
        case .copiedToClipboard:
            return L("已粘贴到剪贴板", "Copied to clipboard")
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
    case finalized(text: String, injection: InjectionOutcome)
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
