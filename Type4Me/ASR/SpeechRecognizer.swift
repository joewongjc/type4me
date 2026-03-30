import Foundation
@preconcurrency import AVFoundation

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    var boostingTableID: String?
    var contextHistoryLength: Int = 20
}

struct RecognitionTranscript: Sendable, Equatable {
    let confirmedSegments: [String]
    let partialText: String
    let authoritativeText: String
    let isFinal: Bool

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
