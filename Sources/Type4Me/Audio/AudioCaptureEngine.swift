@preconcurrency import AVFoundation
import AppKit
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

final class AudioCaptureEngine: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate, AudioCapturing {
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

    static func makePCMBuffer(from pcmData: Data) -> AVAudioPCMBuffer? {
        guard pcmData.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        guard let mData = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        pcmData.copyBytes(to: mData.assumingMemoryBound(to: UInt8.self), count: pcmData.count)
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(pcmData.count)
        return buffer
    }

    // MARK: - Device Selection

    /// Set before calling `start()`. Empty string or nil means system default.
    var selectedDeviceUID: String? {
        didSet {
            if oldValue != selectedDeviceUID {
                prepareIfEligible()
            }
        }
    }

    static var isPreparedCaptureSessionEnabled: Bool {
        let key = "tf_audioPreparedCaptureSession"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }
    /// Returns rich metadata for available audio input devices.
    static func availableAudioInputDevices() -> [AudioInputDevice] {
        AudioInputDeviceDiscovery.availableInputDevices()
    }

    /// Returns a list of available audio input devices (UID + display name).
    static func availableAudioDevices() -> [(uid: String, name: String)] {
        availableAudioInputDevices().map { (uid: $0.uid, name: $0.name) }
    }

    /// Resolve the capture device. An explicit device that disappears must fail
    /// instead of silently switching to the system-default Bluetooth microphone.
    private func resolveDevice() -> AVCaptureDevice? {
        if let uid = selectedDeviceUID, !uid.isEmpty {
            return AVCaptureDevice(uniqueID: uid)
        }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Public

    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFirstSample: (@Sendable (ContinuousClock.Instant) -> Void)?

    private(set) var lastStartInfo = AudioCaptureStartInfo()

    // MARK: - Private

    private struct PreparedCapture {
        let session: AVCaptureSession
        let input: AVCaptureDeviceInput
        let output: AVCaptureAudioDataOutput
        let deviceUID: String
        let isAggregate: Bool
        let topologyObserver: AggregateTopologyObserver?
    }

    /// Idle graph only. Once activated, the graph is owned by `captureSession`
    /// and returns here only if `stop()` decides it can be reused.
    private var prepared: PreparedCapture?
    /// Aggregate observer carried over from a prepared graph while it is running.
    private var runningTopologyObserver: AggregateTopologyObserver?
    private var pendingInvalidate = false
    private let configurationQueue = DispatchQueue(label: "com.type4me.audiocapture.config", qos: .userInitiated)
    private var notificationObservers: [NSObjectProtocol] = []
    private let firstSampleLock = NSLock()
    private var hasEmittedFirstSample = false

    private var captureSession: AVCaptureSession?
    private let stateLock = NSLock()
    private let bufferLock = NSLock()
    private var buffer = Data()
    /// Packet size for the current recording; guarded by `bufferLock`.
    private var activeChunkByteSize = AudioCaptureEngine.chunkByteSize
    private var accumulatedAudio = Data()
    private var converter: AVAudioConverter?
    private let outputQueue = DispatchQueue(label: "com.type4me.audiocapture")
    private let outputQueueKey = DispatchSpecificKey<UInt8>()
    private let outputQueueTag: UInt8 = 1
    private var activeOutput: AVCaptureAudioDataOutput?
    private var levelCounter = 0

    // MARK: - Warm-up

    private var isWarmedUp = false
    override init() {
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: outputQueueTag)
        setupNotificationObservers()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        prepared?.topologyObserver?.invalidate()
        runningTopologyObserver?.invalidate()
    }

    private func setupNotificationObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notif in
                guard let device = notif.object as? AVCaptureDevice else { return }
                self?.configurationQueue.async { [weak self] in
                    if self?.prepared?.deviceUID == device.uniqueID {
                        self?.invalidatePreparedSynchronously(reason: "device-disconnected")
                    }
                }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] _ in
                self?.configurationQueue.async { [weak self] in
                    self?.invalidatePreparedSynchronously(reason: "runtime-error")
                }
            }
        )
        let wsCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.configurationQueue.async { [weak self] in
                    self?.invalidatePreparedSynchronously(reason: "sleep")
                }
            }
        )
        notificationObservers.append(
            wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.configurationQueue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                    self?.prepareIfEligibleSynchronously()
                }
            }
        )
    }

    /// Pre-initialize the audio capture pipeline or prepared session so the first real recording starts instantly.
    func warmUp() {
        prepareIfEligible()
    }

    func prepareIfEligible() {
        configurationQueue.async { [weak self] in
            self?.prepareIfEligibleSynchronously()
        }
    }

    func invalidatePrepared(reason: String) {
        configurationQueue.async { [weak self] in
            self?.invalidatePreparedSynchronously(reason: reason)
        }
    }

    private func invalidatePreparedSynchronously(reason: String) {
        if captureSession != nil {
            // The running graph is never torn down mid-recording; stop() detaches
            // it instead of retaining it.
            pendingInvalidate = true
        }
        guard let p = prepared else { return }
        p.topologyObserver?.invalidate()
        p.session.beginConfiguration()
        p.session.removeOutput(p.output)
        p.session.removeInput(p.input)
        p.session.commitConfiguration()
        prepared = nil
        DebugFileLogger.log("audio capture prepared invalidated reason=\(reason)")
    }

    private func isAggregateDevice(_ device: AVCaptureDevice) -> Bool {
        guard let deviceID = AudioInputDeviceDiscovery.coreAudioDeviceID(forUID: device.uniqueID) else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr && transport == kAudioDeviceTransportTypeAggregate
    }

    private func makeTopologyObserver(uid: String) -> AggregateTopologyObserver? {
        AggregateTopologyObserver(aggregateUID: uid, queue: configurationQueue) { [weak self] in
            // Handle on a later queue turn so invalidation never runs inside the
            // CoreAudio listener block that delivered the change.
            self?.configurationQueue.async { [weak self] in
                self?.handleAggregateTopologyChange(uid: uid)
            }
        }
    }

    private func handleAggregateTopologyChange(uid: String) {
        let isBT = AudioInputDeviceDiscovery.aggregateContainsBluetooth(uid: uid)
        let eligible = !isBT
        if captureSession != nil {
            pendingInvalidate = true
            DebugFileLogger.log("audio aggregate topology changed uid=\(uid) state=running eligible=\(eligible)")
        } else {
            DebugFileLogger.log("audio aggregate topology changed uid=\(uid) state=prepared eligible=\(eligible)")
            invalidatePreparedSynchronously(reason: "aggregate-topology-change")
            if eligible {
                prepareIfEligibleSynchronously()
            }
        }
    }

    private func prepareIfEligibleSynchronously() {
        guard Self.isPreparedCaptureSessionEnabled else {
            invalidatePreparedSynchronously(reason: "disabled")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            invalidatePreparedSynchronously(reason: "no-permission")
            return
        }
        guard captureSession == nil else {
            return
        }
        guard let target = resolveDevice() else {
            invalidatePreparedSynchronously(reason: "no-target")
            return
        }
        let cat = AudioInputDeviceDiscovery.category(for: target)
        let isAgg = isAggregateDevice(target)
        let isAggWithBT = isAgg && AudioInputDeviceDiscovery.aggregateContainsBluetooth(uid: target.uniqueID)
        guard AudioCapturePreparationPolicy.allowsPreparedSession(for: cat, isAggregateWithBluetooth: isAggWithBT) else {
            invalidatePreparedSynchronously(reason: "ineligible(\(cat.rawValue))")
            return
        }

        if let p = prepared {
            if p.deviceUID == target.uniqueID && target.isConnected && (!p.isAggregate || !AudioInputDeviceDiscovery.aggregateContainsBluetooth(uid: p.deviceUID)) {
                return
            } else {
                invalidatePreparedSynchronously(reason: "device-mismatch")
            }
        }

        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: target)
            guard session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)

            let observer = isAgg ? makeTopologyObserver(uid: target.uniqueID) : nil

            prepared = PreparedCapture(
                session: session,
                input: input,
                output: output,
                deviceUID: target.uniqueID,
                isAggregate: isAgg,
                topologyObserver: observer
            )
            DebugFileLogger.log("audio capture prepared for device=\(target.localizedName) uid=\(target.uniqueID)")
        } catch {
            DebugFileLogger.log("audio capture prepare failed: \(error)")
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            configurationQueue.async { [weak self] in
                self?.invalidatePreparedSynchronously(reason: "permission-denied")
            }
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Reset state
        let chunkByteSize = VolcTuningStorage.effective(for: KeychainService.selectedASRProvider).audioChunkByteSize
        bufferLock.lock()
        buffer = Data()
        accumulatedAudio = Data()
        activeChunkByteSize = chunkByteSize
        bufferLock.unlock()
        converter = nil
        firstSampleLock.withLock {
            hasEmittedFirstSample = false
        }

        try configurationQueue.sync {
            try startSynchronously()
        }
    }

    private func startSynchronously() throws {
        guard let target = resolveDevice() else {
            throw AudioCaptureError.noInputDevice
        }
        let targetCategory = AudioInputDeviceDiscovery.category(for: target)
        let isAgg = isAggregateDevice(target)
        let isAggWithBT = isAgg && AudioInputDeviceDiscovery.aggregateContainsBluetooth(uid: target.uniqueID)

        var canReuse = false
        if Self.isPreparedCaptureSessionEnabled,
           let p = prepared,
           p.deviceUID == target.uniqueID,
           target.isConnected,
           (!p.isAggregate || !AudioInputDeviceDiscovery.aggregateContainsBluetooth(uid: p.deviceUID)) {
            canReuse = true
        }

        if canReuse, let p = prepared {
            // Hand the graph to the running capture so idle-graph invalidation
            // can never tear down an active recording.
            prepared = nil
            runningTopologyObserver = p.topologyObserver
            stateLock.withLock {
                activeOutput = p.output
            }
            p.output.setSampleBufferDelegate(self, queue: outputQueue)
            let tStart = ContinuousClock.now
            p.session.startRunning()
            let runningDuration = ContinuousClock.now - tStart
            captureSession = p.session
            isWarmedUp = true
            lastStartInfo = AudioCaptureStartInfo(
                deviceInputDuration: nil,
                startRunningDuration: runningDuration,
                preparedStatus: "hit",
                deviceCategory: targetCategory.rawValue
            )
            DebugFileLogger.log("audio capture started prepared=hit device=\(target.localizedName)")
        } else {
            let missReason: String
            if !Self.isPreparedCaptureSessionEnabled {
                missReason = "disabled"
            } else if targetCategory == .bluetooth {
                missReason = "n/a(bluetooth)"
            } else if isAggWithBT {
                missReason = "n/a(aggregate-bluetooth)"
            } else if targetCategory == .other {
                missReason = "n/a(other)"
            } else if let p = prepared, p.deviceUID != target.uniqueID {
                missReason = "miss(mismatch)"
            } else {
                missReason = "miss(cold)"
            }

            invalidatePreparedSynchronously(reason: missReason)

            let session = AVCaptureSession()
            let tInput = ContinuousClock.now
            let input = try AVCaptureDeviceInput(device: target)
            let inputDuration = ContinuousClock.now - tInput

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
            stateLock.withLock {
                activeOutput = output
            }

            let tStart = ContinuousClock.now
            session.startRunning()
            let runningDuration = ContinuousClock.now - tStart
            captureSession = session
            isWarmedUp = true
            lastStartInfo = AudioCaptureStartInfo(
                deviceInputDuration: inputDuration,
                startRunningDuration: runningDuration,
                preparedStatus: missReason,
                deviceCategory: targetCategory.rawValue
            )
            DebugFileLogger.log("audio capture started prepared=\(missReason) device=\(target.localizedName)")
        }
    }

    func stop() {
        configurationQueue.sync {
            stopSynchronously()
        }
        flushRemaining()
        clearCaptureState()
    }

    private func stopSynchronously() {
        guard let session = captureSession else {
            return
        }

        session.stopRunning()
        drainOutputQueue()

        let output = stateLock.withLock { () -> AVCaptureAudioDataOutput? in
            let current = activeOutput
            activeOutput = nil
            return current
        }
        output?.setSampleBufferDelegate(nil, queue: nil)

        // Decide from the device this graph actually captured: the resolved
        // target may have moved (e.g. AirPods → built-in) during the recording.
        let capturedInput = session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
        let capturedDevice = capturedInput?.device
        let capturedCategory = capturedDevice.map { AudioInputDeviceDiscovery.category(for: $0) } ?? .other
        let isAgg = capturedDevice.map { isAggregateDevice($0) } ?? false
        let isAggWithBT = isAgg && (capturedDevice.map { AudioInputDeviceDiscovery.aggregateContainsBluetooth(uid: $0.uniqueID) } ?? true)
        let retain = AudioCapturePreparationPolicy.shouldRetainAfterStop(
            isEnabled: Self.isPreparedCaptureSessionEnabled,
            pendingInvalidate: pendingInvalidate,
            capturedDeviceUID: capturedDevice?.uniqueID,
            capturedCategory: capturedCategory,
            capturedIsAggregateWithBluetooth: isAggWithBT,
            targetDeviceUID: resolveDevice()?.uniqueID
        )

        if retain, let capturedInput, let capturedDevice, let output {
            let observer = isAgg
                ? (runningTopologyObserver ?? makeTopologyObserver(uid: capturedDevice.uniqueID))
                : nil
            if observer !== runningTopologyObserver {
                runningTopologyObserver?.invalidate()
            }
            runningTopologyObserver = nil
            prepared = PreparedCapture(
                session: session,
                input: capturedInput,
                output: output,
                deviceUID: capturedDevice.uniqueID,
                isAggregate: isAgg,
                topologyObserver: observer
            )
            captureSession = nil
            DebugFileLogger.log("audio capture stopped; prepared session retained device=\(capturedDevice.localizedName)")
        } else {
            session.beginConfiguration()
            for captureOutput in session.outputs {
                session.removeOutput(captureOutput)
            }
            for captureInput in session.inputs {
                session.removeInput(captureInput)
            }
            session.commitConfiguration()
            runningTopologyObserver?.invalidate()
            runningTopologyObserver = nil
            prepared?.topologyObserver?.invalidate()
            prepared = nil
            captureSession = nil
            DebugFileLogger.log(
                "audio capture stopped; AVCapture graph detached "
                    + "captured=\(capturedCategory.rawValue) pendingInvalidate=\(pendingInvalidate)"
            )
        }

        pendingInvalidate = false

        if prepared == nil {
            configurationQueue.async { [weak self] in
                self?.prepareIfEligibleSynchronously()
            }
        }
    }

    private func clearCaptureState() {
        bufferLock.lock()
        converter = nil
        onAudioChunk = nil
        onAudioLevel = nil
        bufferLock.unlock()
        levelCounter = 0
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let isActiveOutput = stateLock.withLock { activeOutput === output }
        firstSampleLock.withLock {
            if !hasEmittedFirstSample {
                hasEmittedFirstSample = true
                let sampleTime = ContinuousClock.now
                onFirstSample?(sampleTime)
            }
        }
        guard isActiveOutput else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        // Emit audio level ~20 times/sec (every 3rd callback at typical 60Hz buffer rate)
        levelCounter += 1
        if levelCounter % 3 == 0, let onAudioLevel {
            let level = Self.calculateLevel(from: pcmBuffer)
            onAudioLevel(level)
        }

        // Heartbeat log every ~5s (300 callbacks at ~60Hz)
        if levelCounter % 300 == 0 {
            let level = Self.calculateLevel(from: pcmBuffer)
            DebugFileLogger.log("audio heartbeat callback=\(levelCounter) bufferSize=\(buffer.count) level=\(String(format: "%.3f", level))")
        }

        // Create or recreate converter when source format changes
        bufferLock.lock()
        let sourceFormat = pcmBuffer.format
        if converter == nil || converter?.inputFormat != sourceFormat {
            if converter != nil {
                NSLog("[Audio] Input format changed, rebuilding converter: %@", sourceFormat.description)
            }
            converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
            NSLog("[Audio] Input format: %@", sourceFormat.description)
            DebugFileLogger.log(
                "audio input format rate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount) interleaved=\(sourceFormat.isInterleaved)"
            )
        }
        guard let conv = converter else {
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()
        convert(buffer: pcmBuffer, using: conv)
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
        while buffer.count >= activeChunkByteSize {
            let chunk = buffer.prefix(activeChunkByteSize)
            buffer.removeFirst(activeChunkByteSize)
            onAudioChunk?(Data(chunk))
        }
    }

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

    private func drainOutputQueue() {
        if DispatchQueue.getSpecific(key: outputQueueKey) == outputQueueTag {
            return  // already on outputQueue, skip to avoid deadlock
        }
        outputQueue.sync {}
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

        if let floatData = pcmBuffer.floatChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: floatData[0])
        } else if let int16Data = pcmBuffer.int16ChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: int16Data[0])
        } else {
            return nil
        }

        return pcmBuffer
    }
}
