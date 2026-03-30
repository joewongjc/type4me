import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import os

enum AppleASRError: Error, LocalizedError {
    case invalidConfig
    case permissionDenied
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Apple ASR requires AppleASRConfig"
        case .permissionDenied:
            return L("未授予语音识别权限", "Speech recognition permission not granted")
        case .recognizerUnavailable:
            return L("Apple 语音识别当前不可用", "Apple speech recognition is currently unavailable")
        }
    }
}

actor AppleASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "AppleASRClient")
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
    private var latestTranscript = ""
    private var didFinishStream = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var didLogInputBuffer = false

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        _events = stream
        eventContinuation = continuation
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let config = config as? AppleASRConfig else {
            throw AppleASRError.invalidConfig
        }
        _ = options

        let hasPermission: Bool
        if PermissionManager.hasSpeechRecognitionPermission {
            hasPermission = true
        } else {
            hasPermission = await PermissionManager.requestSpeechRecognitionPermission()
        }
        guard hasPermission else {
            throw AppleASRError.permissionDenied
        }

        let locale = Self.preferredLocale(for: config)
        logger.info("Apple ASR connect locale=\(locale.identifier, privacy: .public)")

        let recognizerState = await MainActor.run { () -> (SFSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest)? in
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                return nil
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = false
            return (recognizer, request)
        }

        guard let (recognizer, request) = recognizerState else {
            throw AppleASRError.recognizerUnavailable
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        _events = stream
        eventContinuation = continuation
        latestTranscript = ""
        didFinishStream = false
        finishContinuation = nil
        didLogInputBuffer = false
        self.recognizer = recognizer
        self.recognitionRequest = request
        self.recognitionTask = await MainActor.run {
            recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                Task { await self.handleRecognitionCallback(result: result, error: error) }
            }
        }

        continuation.yield(.ready)
    }

    func sendAudio(_ data: Data) async throws {
        _ = data
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        if !didLogInputBuffer {
            didLogInputBuffer = true
            logger.info(
                "append first buffer sr=\(buffer.format.sampleRate, privacy: .public) ch=\(buffer.format.channelCount, privacy: .public) frames=\(buffer.frameLength, privacy: .public) fmt=\(buffer.format.commonFormat.rawValue, privacy: .public) interleaved=\(buffer.format.isInterleaved, privacy: .public)"
            )
        }
        let request = recognitionRequest
        await MainActor.run {
            request?.append(buffer)
        }
    }

    func endAudio() async throws {
        logger.info("Apple ASR endAudio")
        let request = recognitionRequest
        await MainActor.run {
            request?.endAudio()
        }

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return true }
                await self.waitForCompletion()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }

            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }

        if !completed {
            logger.error("Apple ASR endAudio timeout, using fallback transcript")
            finishStream(emitFallbackFinal: true, error: nil)
        }
    }

    func disconnect() async {
        let task = recognitionTask
        await MainActor.run {
            task?.cancel()
        }
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
        finishStream(emitFallbackFinal: false, error: nil)
        eventContinuation = nil
        _events = nil
        latestTranscript = ""
        didFinishStream = false
        finishContinuation = nil
    }

    private func handleRecognitionCallback(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)

            logger.info("Apple ASR callback final=\(result.isFinal, privacy: .public) chars=\(text.count, privacy: .public)")

            if !text.isEmpty {
                latestTranscript = text
                eventContinuation?.yield(Self.makeTranscript(text: text, isFinal: result.isFinal))
            }

            if result.isFinal {
                finishStream(emitFallbackFinal: false, error: nil)
                return
            }
        }

        if let error {
            logger.error("Apple ASR callback error: \(String(describing: error), privacy: .public)")
            finishStream(emitFallbackFinal: true, error: error)
        }
    }

    private func waitForCompletion() async {
        if didFinishStream { return }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    private func finishStream(emitFallbackFinal: Bool, error: Error?) {
        guard !didFinishStream else { return }
        didFinishStream = true

        if emitFallbackFinal, !latestTranscript.isEmpty {
            eventContinuation?.yield(Self.makeTranscript(text: latestTranscript, isFinal: true))
        }

        if let error {
            eventContinuation?.yield(.error(error))
        }

        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
        finishContinuation?.resume()
        finishContinuation = nil
    }

    static func preferredLocale(for config: AppleASRConfig) -> Locale {
        Locale(identifier: config.localeIdentifier)
    }

    private static func makeTranscript(text: String, isFinal: Bool) -> RecognitionEvent {
        .transcript(
            RecognitionTranscript(
                confirmedSegments: isFinal ? [text] : [],
                partialText: isFinal ? "" : text,
                authoritativeText: isFinal ? text : "",
                isFinal: isFinal
            )
        )
    }
}
