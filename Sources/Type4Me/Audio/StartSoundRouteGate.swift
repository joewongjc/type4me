import CoreAudio
import AVFoundation
import Foundation

protocol AudioOutputRouteMonitor: AnyObject, Sendable {
    func currentNominalSampleRate(for deviceID: AudioDeviceID) -> Double?
    func addRouteChangeListener(
        for deviceID: AudioDeviceID,
        queue: DispatchQueue,
        onChange: @escaping @Sendable (Double) -> Void
    ) -> (any Sendable)?
    func removeRouteChangeListener(_ token: any Sendable)
}

/// CoreAudio property-listener entry points, injectable so tests can verify that
/// a listener is removed with exactly the arguments it was registered with.
struct CoreAudioListenerAPI: Sendable {
    var add: @Sendable (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping CoreAudioListenerBlock) -> OSStatus
    var remove: @Sendable (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping CoreAudioListenerBlock) -> OSStatus

    static let live = CoreAudioListenerAPI(
        add: { CoreAudioListenerBlocks.add($0, $1, $2, $3) },
        remove: { CoreAudioListenerBlocks.remove($0, $1, $2, $3) }
    )
}

final class CoreAudioOutputRouteMonitor: AudioOutputRouteMonitor, @unchecked Sendable {
    private let listenerAPI: CoreAudioListenerAPI

    init(listenerAPI: CoreAudioListenerAPI = .live) {
        self.listenerAPI = listenerAPI
    }

    func currentNominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        if status == noErr, rate > 0 {
            return Double(rate)
        }
        address.mScope = kAudioObjectPropertyScopeGlobal
        let globalStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard globalStatus == noErr, rate > 0 else { return nil }
        return Double(rate)
    }

    /// Holds only the addresses that registered successfully, plus the queue and
    /// block object they were registered with: CoreAudio removes a block listener
    /// only when the object, address, queue and block all match the registration.
    private final class ListenerToken: @unchecked Sendable {
        let deviceID: AudioDeviceID
        let queue: DispatchQueue
        let addresses: [AudioObjectPropertyAddress]
        let block: CoreAudioListenerBlock
        var isRemoved = false
        let lock = NSLock()

        init(
            deviceID: AudioDeviceID,
            queue: DispatchQueue,
            addresses: [AudioObjectPropertyAddress],
            block: @escaping CoreAudioListenerBlock
        ) {
            self.deviceID = deviceID
            self.queue = queue
            self.addresses = addresses
            self.block = block
        }
    }

    func addRouteChangeListener(
        for deviceID: AudioDeviceID,
        queue: DispatchQueue,
        onChange: @escaping @Sendable (Double) -> Void
    ) -> (any Sendable)? {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyNominalSampleRate,
            kAudioDevicePropertyStreamFormat
        ]
        var addresses: [AudioObjectPropertyAddress] = []
        for selector in selectors {
            addresses.append(AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ))
            addresses.append(AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ))
        }

        let block: CoreAudioListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if let rate = self.currentNominalSampleRate(for: deviceID) {
                onChange(rate)
            }
        }

        var registered: [AudioObjectPropertyAddress] = []
        for address in addresses {
            let status = listenerAPI.add(deviceID, address, queue, block)
            if status == noErr {
                registered.append(address)
            } else {
                DebugFileLogger.log(
                    "start sound route listener add failed selector=\(address.mSelector) scope=\(address.mScope) status=\(status)"
                )
            }
        }
        guard !registered.isEmpty else { return nil }
        return ListenerToken(deviceID: deviceID, queue: queue, addresses: registered, block: block)
    }

    func removeRouteChangeListener(_ token: any Sendable) {
        guard let listenerToken = token as? ListenerToken else { return }
        listenerToken.lock.withLock {
            guard !listenerToken.isRemoved else { return }
            listenerToken.isRemoved = true
            for address in listenerToken.addresses {
                let status = listenerAPI.remove(
                    listenerToken.deviceID, address, listenerToken.queue, listenerToken.block
                )
                if status != noErr {
                    DebugFileLogger.log(
                        "start sound route listener remove failed selector=\(address.mSelector) scope=\(address.mScope) status=\(status)"
                    )
                }
            }
        }
    }
}

/// Arms before capture starts so a Bluetooth A2DP→HFP switch is observed,
/// and lets the start sound wait until the shared output route has settled.
final class StartSoundRouteGate: @unchecked Sendable {
    enum Outcome: String, Sendable {
        case notRequired
        case alreadySettled
        case switched
        case timeout
        case cancelled
    }

    static let shared = StartSoundRouteGate()

    private let routeMonitor: any AudioOutputRouteMonitor
    private let queue = DispatchQueue(label: "com.type4me.startsoundroutegate", qos: .userInitiated)
    private let stateLock = NSLock()

    private var currentGeneration: UInt64 = 0
    private var isDisarmed: Bool = true
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    private var listenerToken: (any Sendable)?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    init(routeMonitor: any AudioOutputRouteMonitor = CoreAudioOutputRouteMonitor()) {
        self.routeMonitor = routeMonitor
    }

    /// Thread-safe; true only while `generation` is the armed, not-yet-disarmed round.
    func isCurrent(generation: UInt64) -> Bool {
        stateLock.withLock {
            currentGeneration == generation && !isDisarmed
        }
    }

    /// Called by RecognitionSession before audioEngine.start().
    func arm(generation: UInt64, inputDevice: AVCaptureDevice?) {
        stateLock.withLock {
            currentGeneration = generation
            isDisarmed = false
            outcome = nil
        }
        queue.async { [weak self] in
            self?.armSynchronously(generation: generation, inputDevice: inputDevice)
        }
    }

    private func armSynchronously(generation: UInt64, inputDevice: AVCaptureDevice?) {
        // Cancel prior round's waiters and tasks
        cleanupCurrentRound(newGeneration: generation)

        guard stateLock.withLock({ currentGeneration == generation && !isDisarmed }) else { return }

        guard let inputDevice else {
            setOutcomeAndResumeWaiters(.notRequired, for: generation)
            return
        }

        let inputCategory = AudioInputDeviceDiscovery.category(for: inputDevice)
        let inputInfo = (uid: inputDevice.uniqueID, name: inputDevice.localizedName)
        let outputInfo = resolveCurrentOutputDeviceInfo()

        let isStartSoundEnabled = UserDefaults.standard.string(forKey: "tf_startSound") != "off"
        let requiresSettle = StartSoundRoutePolicy.requiresRouteSettle(
            startSoundEnabled: isStartSoundEnabled,
            inputCategory: inputCategory,
            input: inputInfo,
            output: outputInfo.map { (uid: $0.uid, name: $0.name, isBluetooth: $0.isBluetooth) }
        )

        guard requiresSettle, let outputDeviceID = outputInfo?.deviceID else {
            setOutcomeAndResumeWaiters(.notRequired, for: generation)
            return
        }

        let currentRate = routeMonitor.currentNominalSampleRate(for: outputDeviceID)
        if let currentRate, currentRate <= 24000.0 {
            DebugFileLogger.log("start sound gate alreadySettled rate=\(currentRate) gen=\(generation)")
            setOutcomeAndResumeWaiters(.alreadySettled, for: generation)
            return
        }

        DebugFileLogger.log("start sound gate waiting for route settle rate=\(currentRate ?? -1) gen=\(generation)")

        // Register route listener
        listenerToken = routeMonitor.addRouteChangeListener(for: outputDeviceID, queue: queue) { [weak self] newRate in
            self?.handleRateChange(newRate: newRate, generation: generation)
        }
        if listenerToken == nil {
            DebugFileLogger.log("start sound gate listener unavailable; relying on timeout gen=\(generation)")
        }

        // Arm 900ms timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.queue.async {
                self?.handleTimeout(generation: generation)
            }
        }
    }

    private func handleRateChange(newRate: Double, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }
        guard outcome == nil else { return }

        if newRate <= 24000.0 {
            if let token = listenerToken {
                routeMonitor.removeRouteChangeListener(token)
                listenerToken = nil
            }
            timeoutTask?.cancel()
            timeoutTask = nil

            // 300ms settling buffer to let Bluetooth hardware DAC, SCO packet buffers and AGC settle
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.queue.async {
                    guard let self, self.isCurrent(generation: generation), self.outcome == nil else { return }
                    DebugFileLogger.log("start sound gate switched rate=\(newRate) gen=\(generation)")
                    self.setOutcomeAndResumeWaiters(.switched, for: generation)
                }
            }
        }
    }

    private func handleTimeout(generation: UInt64) {
        guard isCurrent(generation: generation) else { return }
        guard outcome == nil else { return }

        if let token = listenerToken {
            routeMonitor.removeRouteChangeListener(token)
            listenerToken = nil
        }
        settleTask?.cancel()
        settleTask = nil

        DebugFileLogger.log("start sound gate timeout gen=\(generation)")
        setOutcomeAndResumeWaiters(.timeout, for: generation)
    }

    /// Awaited by Type4MeApp before SoundFeedback.playStart().
    func waitUntilSettled(generation: UInt64) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let isValid = self.stateLock.withLock {
                    self.currentGeneration == generation && !self.isDisarmed
                }
                guard isValid else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if let resolved = self.stateLock.withLock({ self.outcome }) {
                    continuation.resume(returning: resolved)
                    return
                }
                self.waiters.append(continuation)
            }
        }
    }

    /// Called on stop / cancel / forceReset; removes listeners and resumes waiters.
    func disarm(generation: UInt64) {
        stateLock.withLock {
            if currentGeneration == generation {
                isDisarmed = true
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            let isMatching = self.stateLock.withLock {
                self.currentGeneration == generation
            }
            guard isMatching else { return }
            self.cleanupCurrentRound(newGeneration: nil)
        }
    }

    private func cleanupCurrentRound(newGeneration: UInt64?) {
        if let token = listenerToken {
            routeMonitor.removeRouteChangeListener(token)
            listenerToken = nil
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        settleTask?.cancel()
        settleTask = nil

        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: .cancelled)
        }
    }

    private func setOutcomeAndResumeWaiters(_ result: Outcome, for generation: UInt64) {
        guard stateLock.withLock({ currentGeneration == generation && !isDisarmed }) else { return }
        stateLock.withLock {
            outcome = result
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    private func resolveCurrentOutputDeviceInfo() -> (deviceID: AudioDeviceID, uid: String, name: String, isBluetooth: Bool)? {
        let explicitUID = UserDefaults.standard.string(forKey: "tf_selectedSpeakerUID") ?? ""
        var targetDeviceID: AudioDeviceID?
        if !explicitUID.isEmpty, let id = AudioInputDeviceDiscovery.coreAudioDeviceID(forUID: explicitUID) {
            targetDeviceID = id
        } else {
            var defaultID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &defaultID
            )
            if status == noErr, defaultID != kAudioObjectUnknown {
                targetDeviceID = defaultID
            }
        }

        guard let deviceID = targetDeviceID else { return nil }

        // Get UID
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef)
        let uid = (uidStatus == noErr ? uidRef?.takeRetainedValue() as String? : nil) ?? ""

        // Get Name
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
        let name = (nameStatus == noErr ? nameRef?.takeRetainedValue() as String? : nil) ?? ""

        // Get Transport
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport)
        let isTransportBT = transportStatus == noErr && (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        let isNameBT = name.lowercased().contains("airpods") || name.lowercased().contains("bluetooth") || name.contains("蓝牙")

        return (deviceID: deviceID, uid: uid, name: name, isBluetooth: isTransportBT || isNameBT)
    }
}
