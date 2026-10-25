import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// iOS's own speech recognizer, so dictation works with no account or API
/// key. Uses the Mac's `AppleASRConfig` (language only). Recognition stays on
/// the iPhone whenever iOS supports the language on device; otherwise iOS
/// sends the audio to Apple.
///
/// The Mac's `AppleASRClient` takes `AVAudioPCMBuffer`s from its own capture;
/// here audio arrives as the shared 16 kHz, 16-bit mono chunks.
actor AppleSpeechClient: SpeechRecognizer {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<RecognitionEvent>.Continuation?
    private var stream: AsyncStream<RecognitionEvent>?
    private var latest = ""
    private var finished = false
    private var finishWaiter: CheckedContinuation<Void, Never>?

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var events: AsyncStream<RecognitionEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    /// Asks for speech recognition access. Call while the app is in front;
    /// iOS can't show the prompt from the background.
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// The test in Settings: access granted and a recognizer for the language.
    static func validate(_ config: any ASRProviderConfig) async throws {
        guard let config = config as? AppleASRConfig else { throw AppleSpeechError.invalidConfig }
        guard await requestAuthorization() else { throw AppleSpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: config.localeIdentifier)), recognizer.isAvailable else {
            throw AppleSpeechError.unavailable
        }
    }

    /// The recognition language that matches the iPhone's language.
    static var defaultLocaleIdentifier: String {
        switch Locale.current.language.languageCode?.identifier {
        case "zh": return "zh-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        default: return "en-US"
        }
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let config = config as? AppleASRConfig else { throw AppleSpeechError.invalidConfig }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw AppleSpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: config.localeIdentifier)), recognizer.isAvailable else {
            throw AppleSpeechError.unavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        #if DEBUG
        if ProcessInfo.processInfo.environment["T4M_SPEECH_SERVER"] == "1" { request.requiresOnDeviceRecognition = false }
        #endif
        request.addsPunctuation = options.enablePunc
        request.contextualStrings = Array(options.hotwords.prefix(100))

        _ = events
        latest = ""
        finished = false
        self.recognizer = recognizer
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            let isFinal = result?.isFinal ?? false
            Task { await self?.handle(text: text, isFinal: isFinal, error: error) }
        }
        continuation?.yield(.ready)
    }

    func sendAudio(_ data: Data) async throws {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(samples[i]) / 32_768 }
        }
        request?.append(buffer)
    }

    func endAudio() async throws {
        request?.endAudio()
        // The final result normally arrives within a second; keep the
        // partial text if it doesn't.
        let done = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitForFinish(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
        if !done { finish(final: true, error: nil) }
    }

    func disconnect() async {
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        finish(final: false, error: nil)
    }

    private func handle(text: String?, isFinal: Bool, error: Error?) {
        guard !finished else { return }
        if let text, !text.isEmpty {
            latest = text
            continuation?.yield(Self.transcript(text, isFinal: isFinal))
        }
        if isFinal { finish(final: false, error: nil); return }
        if let error { finish(final: true, error: latest.isEmpty ? error : nil) }
    }

    private func waitForFinish() async {
        if finished { return }
        await withCheckedContinuation { finishWaiter = $0 }
    }

    private func finish(final emitLatest: Bool, error: Error?) {
        guard !finished else { return }
        finished = true
        if emitLatest, !latest.isEmpty { continuation?.yield(Self.transcript(latest, isFinal: true)) }
        if let error { continuation?.yield(.error(error)) }
        continuation?.yield(.completed)
        continuation?.finish()
        finishWaiter?.resume()
        finishWaiter = nil
    }

    private static func transcript(_ text: String, isFinal: Bool) -> RecognitionEvent {
        .transcript(RecognitionTranscript(
            confirmedSegments: isFinal ? [text] : [],
            partialText: isFinal ? "" : text,
            authoritativeText: isFinal ? text : "",
            isFinal: isFinal
        ))
    }
}

enum AppleSpeechError: LocalizedError {
    case invalidConfig
    case notAuthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfig: return L("Apple 语音识别配置无效", "The Apple Speech setup is invalid")
        case .notAuthorized: return L("需要允许语音识别：打开 Type4Me，在设置里测试一次 Apple 语音识别", "Speech recognition isn't allowed. Open Type4Me and test Apple Speech in Settings.")
        case .unavailable: return L("Apple 语音识别暂时不可用", "Apple Speech isn't available right now")
        }
    }
}
