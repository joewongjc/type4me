import AudioToolbox
import CoreAudio
import Foundation
import os

/// Manages system output volume: save, lower, and restore.
/// Uses CoreAudio directly — no private APIs.
/// All CoreAudio work runs on a dedicated background queue to avoid blocking
/// the caller (Bluetooth audio devices can stall AudioObject*PropertyData for seconds).
enum SystemVolumeManager {

    static let volumeReductionKey = "tf_volumeReduction"

    private static let logger = Logger(subsystem: "com.type4me.volume", category: "SystemVolumeManager")

    /// Dedicated serial queue for CoreAudio property access.
    private static let queue = DispatchQueue(label: "com.type4me.volume.coreaudio", qos: .userInitiated)

    private static let transaction = VolumeRestorationTransaction(
        defaults: .standard, audio: CoreAudioVolumeAdapter(),
        enqueue: { work in queue.async(execute: work) },
        schedule: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) },
        log: { message in logger.info("\(message, privacy: .public)") }
    )

    static func configuredReductionPercent(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: volumeReductionKey) as? NSNumber else {
            return -1
        }
        return value.intValue
    }

    static func reserveAttenuation() -> UInt64 { transaction.reserveAttenuation() }

    static func lower(to fraction: Float, token: UInt64) {
        transaction.lower(to: fraction, token: token)
    }

    static func restore() { transaction.restore() }

    /// Recovery uses the same asynchronous, verified path as normal restoration.
    static func restoreIfNeeded() { transaction.restore() }

    // MARK: - Start Sound Delay

    /// Compute the optimal delay between recording start and alert sound playback,
    /// based on whether the input and output are the same physical Bluetooth device.
    /// Mirrors the Typeless approach: same BT device → 1200ms, AirPods → 300ms,
    /// separate BT speaker → 100ms (codec wake-up), wired/built-in → 0.
    static func startSoundDelay() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: startSoundDelayOnQueue()) }
        }
    }

    private static func startSoundDelayOnQueue() -> Int {
        guard let outputID = defaultOutputDevice() else { return 0 }

        let outTransport = transportType(device: outputID)
        let isBTOutput = outTransport == kAudioDeviceTransportTypeBluetooth
            || outTransport == kAudioDeviceTransportTypeBluetoothLE

        guard isBTOutput else { return 0 }

        // BT output. Check if input is the same physical device.
        guard let inputID = defaultInputDevice() else { return 100 }

        let outName = deviceName(outputID)?.lowercased() ?? ""
        let inName = deviceName(inputID)?.lowercased() ?? ""

        let isSameDevice = !outName.isEmpty && !inName.isEmpty
            && (outName == inName || outName.contains(inName) || inName.contains(outName))

        if isSameDevice {
            if inName.contains("airpods") { return 300 }
            return 1200
        }

        // Separate BT speaker + different mic: BT amplifier needs wake-up time.
        return 200
    }

    // MARK: - CoreAudio

    private static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    private static func transportType(device: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }
}

/// Implementations are used only on the volume queue.
/// Failure to read or write a property must throw; a property that is missing or
/// not settable must throw `VolumeAudioError.unsupportedProperty`.
protocol VolumeAudioAdapter {
    func defaultOutput() throws -> AudioDeviceID
    func uid(of device: AudioDeviceID) throws -> String
    func device(for uid: String) throws -> AudioDeviceID
    func volume(_ device: AudioDeviceID) throws -> Float
    func setVolume(_ value: Float, on device: AudioDeviceID) throws
}

final class VolumeRestorationTransaction {
    static let recoveryKey = "tf_savedSystemVolumeTransaction"
    static let legacyKey = "tf_savedSystemVolume"

    /// nil uid marks a legacy record, which restores to the current output.
    private struct Snapshot {
        let uid: String?
        let volume: Float
        var key: String { uid ?? "" }
    }

    private let generation = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let defaults: UserDefaults
    private let audio: VolumeAudioAdapter
    private let enqueue: (@escaping () -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void
    // Everything below is owned by the queue, including retry callbacks.
    private var restoring: Set<String> = []
    private let intervals: [TimeInterval] = [0.1, 0.25, 0.5]

    init(defaults: UserDefaults, audio: VolumeAudioAdapter,
         enqueue: @escaping (@escaping () -> Void) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         log: @escaping (String) -> Void) {
        self.defaults = defaults
        self.audio = audio
        self.enqueue = enqueue
        self.schedule = schedule
        self.log = log
    }

    func reserveAttenuation() -> UInt64 {
        generation.withLock { $0 &+= 1; return $0 }
    }

    func lower(to fraction: Float, token: UInt64) {
        enqueue { [self] in
            guard generation.withLock({ $0 == token }), fraction.isFinite,
                  loadLegacy() == nil else { return }
            do {
                var pending = loadPending()
                let device = try audio.defaultOutput()
                let uid = try audio.uid(of: device)
                // Pending recovery for another output does not block this one.
                guard pending[uid] == nil, !restoring.contains(uid) else { return }
                let volume = try audio.volume(device)
                guard !uid.isEmpty, volume.isFinite, (0...1).contains(volume) else {
                    throw VolumeAudioError.invalidValue
                }
                // Don't lower if already very quiet.
                guard volume > 0.05 else { return }
                // Reads can stall. Recheck cancellation immediately before persisting/writing.
                guard generation.withLock({ $0 == token }) else { return }
                pending[uid] = volume
                try savePending(pending)
                do {
                    try audio.setVolume(volume * max(0, min(1, fraction)), on: device)
                } catch {
                    // Nothing was lowered, so there is nothing to recover.
                    pending[uid] = nil
                    try? savePending(pending)
                    throw error
                }
                log("Volume lowered; recovery snapshot retained")
            } catch {
                log("Volume attenuation failed: \(error)")
            }
        }
    }

    func restore() {
        // Invalidate delayed and already queued lowers before returning to the caller.
        _ = reserveAttenuation()
        enqueue { [self] in
            var snapshots = loadPending().map { Snapshot(uid: $0.key, volume: $0.value) }
            if let legacy = loadLegacy() { snapshots.append(legacy) }
            for snapshot in snapshots.sorted(by: { $0.key < $1.key })
            where !restoring.contains(snapshot.key) {
                restoring.insert(snapshot.key)
                attempt(snapshot, index: 0)
            }
        }
    }

    /// Undecodable records are permanent failures: clear them instead of blocking forever.
    private func loadPending() -> [String: Float] {
        guard let stored = defaults.object(forKey: Self.recoveryKey) else { return [:] }
        if let data = stored as? Data,
           let pending = try? JSONDecoder().decode([String: Float].self, from: data),
           pending.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite && (0...1).contains($0.value) }) {
            return pending
        }
        log("Volume recovery record invalid; discarded")
        defaults.removeObject(forKey: Self.recoveryKey)
        return [:]
    }

    private func savePending(_ pending: [String: Float]) throws {
        if pending.isEmpty {
            defaults.removeObject(forKey: Self.recoveryKey)
        } else {
            defaults.set(try JSONEncoder().encode(pending), forKey: Self.recoveryKey)
        }
    }

    private func loadLegacy() -> Snapshot? {
        guard let stored = defaults.object(forKey: Self.legacyKey) else { return nil }
        guard let number = stored as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.floatValue.isFinite, (0...1).contains(number.floatValue) else {
            log("Legacy volume recovery record invalid; discarded")
            defaults.removeObject(forKey: Self.legacyKey)
            return nil
        }
        return Snapshot(uid: nil, volume: number.floatValue)
    }

    private func finish(_ saved: Snapshot, _ message: String) {
        if let uid = saved.uid {
            var pending = loadPending()
            pending[uid] = nil
            try? savePending(pending)
        } else {
            defaults.removeObject(forKey: Self.legacyKey)
        }
        restoring.remove(saved.key)
        log(message)
    }

    private func attempt(_ saved: Snapshot, index: Int) {
        var writtenDevice: AudioDeviceID?
        do {
            let device = try saved.uid.map { try audio.device(for: $0) } ?? audio.defaultOutput()
            try audio.setVolume(saved.volume, on: device)
            writtenDevice = device
        } catch VolumeAudioError.unsupportedProperty {
            // Retrying can never succeed on a device whose volume is not settable.
            finish(saved, "Volume not settable on recovered device; recovery record discarded")
            return
        } catch {
            log("Volume restoration attempt \(index + 1) failed: \(error)")
        }
        schedule(intervals[index]) { [self] in
            do {
                guard let device = writtenDevice else { throw VolumeAudioError.writeFailed }
                if let uid = saved.uid, try audio.device(for: uid) != device {
                    throw VolumeAudioError.deviceUnavailable
                }
                let volume = try audio.volume(device)
                guard volume.isFinite, abs(volume - saved.volume) <= 0.001 else {
                    throw VolumeAudioError.verificationFailed
                }
                finish(saved, "Volume restored and verified")
                return
            } catch {
                log("Volume restoration verification \(index + 1) failed: \(error)")
            }
            if index + 1 < intervals.count {
                attempt(saved, index: index + 1)
            } else {
                restoring.remove(saved.key)
                log("Volume restoration unresolved after bounded retries; recovery retained")
            }
        }
    }
}

enum VolumeAudioError: Error {
    case status(OSStatus), unsupportedProperty(UInt32), deviceUnavailable
    case invalidValue, writeFailed, verificationFailed
}

private struct CoreAudioVolumeAdapter: VolumeAudioAdapter {
    private func address(_ selector: UInt32, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func read<T>(_ device: AudioObjectID, _ selector: UInt32,
                         initial: T, output: Bool = false) throws -> T {
        var property = address(selector, output: output)
        guard AudioObjectHasProperty(device, &property) else {
            throw VolumeAudioError.unsupportedProperty(selector)
        }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0)
        }
        guard status == noErr else { throw VolumeAudioError.status(status) }
        return value
    }

    private func write<T>(_ value: T, device: AudioDeviceID, selector: UInt32) throws {
        var property = address(selector, output: true)
        guard AudioObjectHasProperty(device, &property) else {
            throw VolumeAudioError.unsupportedProperty(selector)
        }
        var settable = DarwinBoolean(false)
        let check = AudioObjectIsPropertySettable(device, &property, &settable)
        guard check == noErr else { throw VolumeAudioError.status(check) }
        guard settable.boolValue else { throw VolumeAudioError.unsupportedProperty(selector) }
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw VolumeAudioError.status(status) }
    }

    func defaultOutput() throws -> AudioDeviceID {
        let device = try read(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        guard device != kAudioObjectUnknown else { throw VolumeAudioError.deviceUnavailable }
        return device
    }

    func uid(of device: AudioDeviceID) throws -> String {
        let value = try read(device, kAudioDevicePropertyDeviceUID, initial: "" as CFString)
        return value as String
    }

    func device(for uid: String) throws -> AudioDeviceID {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size)
        guard status == noErr else { throw VolumeAudioError.status(status) }
        guard size > 0 else { throw VolumeAudioError.deviceUnavailable }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let readStatus = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
        }
        guard readStatus == noErr else { throw VolumeAudioError.status(readStatus) }
        for device in devices where (try? self.uid(of: device)) == uid { return device }
        throw VolumeAudioError.deviceUnavailable
    }

    func volume(_ device: AudioDeviceID) throws -> Float {
        try read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, initial: Float(0), output: true)
    }

    func setVolume(_ value: Float, on device: AudioDeviceID) throws {
        try write(value, device: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    }
}
