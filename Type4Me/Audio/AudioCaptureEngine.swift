@preconcurrency import AVFoundation

enum AudioCaptureError: Error, LocalizedError {
    case converterCreationFailed
    case microphonePermissionDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return L("录音启动失败", "Failed to start recording")
        case .microphonePermissionDenied:
            return L("未授予麦克风权限", "Microphone permission not granted")
        case .noInputDevice:
            return L("找不到麦克风", "No microphone found")
        }
    }
}

final class AudioCaptureEngine: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Static properties

    static let sampleRate: Double = 16000
    static let channels: AVAudioChannelCount = 1
    static let chunkDurationMs: Int = 200
    static let samplesPerChunk: Int = 3200
    static let chunkByteSize: Int = 6400
    static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    // MARK: - Public

    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    /// Set to `false` to bypass VAD filtering (A/B testing).
    var vadEnabled: Bool = true

    // MARK: - VAD

    #if canImport(SherpaOnnxLib)
    private var sileroVAD: SileroVAD?
    #endif
    private let vadFilter = VADFilter()
    private var vadRemainder = [Float]()

    // MARK: - Private

    private var captureSession: AVCaptureSession?
    private let bufferLock = NSLock()
    private var buffer = Data()
    private var accumulatedAudio = Data()
    private var converter: AVAudioConverter?
    private let outputQueue = DispatchQueue(label: "com.type4me.audiocapture")
    private var levelCounter = 0

    // MARK: - Warm-up

    private var isWarmedUp = false
    private var warmSession: AVCaptureSession?

    /// Pre-initialize the audio capture pipeline so the first real recording starts instantly.
    func warmUp() {
        guard !isWarmedUp else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[Audio] Warm-up skipped: microphone permission not granted")
            return
        }
        outputQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else { return }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { return }
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)
                session.startRunning()
                // Keep it alive briefly to fully initialize CoreAudio, then stop
                Thread.sleep(forTimeInterval: 0.3)
                session.stopRunning()
                self.isWarmedUp = true
                NSLog("[Audio] Warm-up complete")
            } catch {
                NSLog("[Audio] Warm-up failed: %@", String(describing: error))
            }
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Reset state
        bufferLock.lock()
        buffer = Data()
        accumulatedAudio = Data()
        vadRemainder.removeAll()
        bufferLock.unlock()
        converter = nil

        // Initialize VAD if enabled and SherpaOnnx is available
        vadFilter.reset()
        #if canImport(SherpaOnnxLib)
        if vadEnabled && sileroVAD == nil {
            sileroVAD = SileroVAD()
            if sileroVAD != nil {
                NSLog("[Audio] Silero VAD initialized")
            }
        }
        sileroVAD?.reset()
        #endif

        try startWithAVCapture()
    }

    private func startWithAVCapture() throws {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureError.noInputDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AudioCaptureError.converterCreationFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw AudioCaptureError.converterCreationFailed
        }
        session.addOutput(output)

        session.startRunning()
        captureSession = session
        isWarmedUp = true
        NSLog("[Audio] Capture session started (AVCapture), device: %@", device.localizedName)
    }

    func stop() {
        captureSession?.stopRunning()
        captureSession = nil
        converter = nil
        levelCounter = 0
        flushRemaining()
        bufferLock.lock()
        vadRemainder.removeAll()
        bufferLock.unlock()
        NSLog("[Audio] Capture session stopped")
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        // Emit audio level ~20 times/sec (every 3rd callback at typical 60Hz buffer rate)
        levelCounter += 1
        if levelCounter % 3 == 0, let onAudioLevel {
            let level = Self.calculateLevel(from: pcmBuffer)
            onAudioLevel(level)
        }

        // Lazy-create converter from source format → 16kHz Int16
        if converter == nil {
            let sourceFormat = pcmBuffer.format
            converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
            NSLog("[Audio] Input format: %@", sourceFormat.description)
        }

        guard let converter else { return }
        convert(buffer: pcmBuffer, using: converter)
    }

    // MARK: - Internal

    private func convert(buffer pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * Self.sampleRate / pcmBuffer.format.sampleRate
        )
        guard frameCapacity > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        nonisolated(unsafe) var hasData = true
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil else { return }

        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }

        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        let chunk = Data(bytes: mData, count: byteCount)

        bufferLock.lock()
        accumulatedAudio.append(chunk)
        buffer.append(chunk)
        emitFullChunks()
        bufferLock.unlock()
    }

    /// Returns the full recorded PCM audio since the last start().
    func getRecordedAudio() -> Data {
        bufferLock.lock()
        let data = accumulatedAudio
        bufferLock.unlock()
        return data
    }

    /// Emit all complete chunks from the buffer. Must be called with bufferLock held.
    private func emitFullChunks() {
        while buffer.count >= Self.chunkByteSize {
            let chunk = Data(buffer.prefix(Self.chunkByteSize))
            buffer.removeFirst(Self.chunkByteSize)

            #if canImport(SherpaOnnxLib)
            if vadEnabled, let vad = sileroVAD {
                if runVAD(on: chunk, vad: vad) {
                    onAudioChunk?(chunk)
                }
                continue
            }
            #endif
            onAudioChunk?(chunk)
        }
    }

    #if canImport(SherpaOnnxLib)
    /// Convert Int16 PCM to Float32, split into 512-sample VAD windows,
    /// and return whether this chunk should be emitted.
    /// Must be called with bufferLock held.
    private func runVAD(on chunk: Data, vad: SileroVAD) -> Bool {
        // Int16 → Float32 [-1, 1]
        let sampleCount = chunk.count / MemoryLayout<Int16>.size
        chunk.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            vadRemainder.reserveCapacity(vadRemainder.count + sampleCount)
            for i in 0..<sampleCount {
                vadRemainder.append(Float(int16s[i]) / 32768.0)
            }
        }

        // Process all complete 512-sample VAD windows
        var shouldEmit = vadFilter.state != .waitingForSpeech

        while vadRemainder.count >= SileroVAD.windowSize {
            let window = Array(vadRemainder.prefix(SileroVAD.windowSize))
            vadRemainder.removeFirst(SileroVAD.windowSize)

            let detected = vad.isSpeechDetected(samples: window)
            shouldEmit = vadFilter.shouldEmit(speechDetected: detected)
        }

        return shouldEmit
    }
    #endif

    /// RMS → normalized 0..1 level from float PCM buffer.
    private static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let ptr = channelData[0]
        var sum: Float = 0
        // Sample every 16th frame for efficiency (256 samples max)
        let stride = max(1, frames / 256)
        var count = 0
        var i = 0
        while i < frames {
            sum += ptr[i] * ptr[i]
            count += 1
            i += stride
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        // Map -50dB..0dB → 0..1
        return max(0, min(1, (db + 50) / 50))
    }

    private func bufferSize() -> Int {
        bufferLock.lock()
        let size = buffer.count
        bufferLock.unlock()
        return size
    }

    private func flushRemaining() {
        bufferLock.lock()
        let remaining = buffer
        buffer = Data()
        bufferLock.unlock()

        if !remaining.isEmpty {
            onAudioChunk?(remaining)
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard let channelData = pcmBuffer.floatChannelData else { return nil }

        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: channelData[0])
        return pcmBuffer
    }
}
