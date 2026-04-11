import AudioToolbox
import CoreAudio
import Foundation
import os

/// Manages system output volume: save, lower, and restore.
/// Uses CoreAudio directly — no private APIs.
/// All CoreAudio work runs on a dedicated background queue to avoid blocking
/// the caller (Bluetooth audio devices can stall AudioObject*PropertyData for seconds).
enum SystemVolumeManager {

    private static let logger = Logger(subsystem: "com.type4me.volume", category: "SystemVolumeManager")

    /// Dedicated serial queue for CoreAudio property access.
    private static let queue = DispatchQueue(label: "com.type4me.volume.coreaudio", qos: .userInitiated)

    /// The volume level saved before lowering, protected for cross-thread access.
    private static let savedVolume = OSAllocatedUnfairLock<Float?>(initialState: nil)

    /// UserDefaults key for crash recovery.
    private static let savedVolumeKey = "tf_savedSystemVolume"

    /// Lower system volume to a fraction of the current level.
    /// Saves the current volume so it can be restored later.
    /// - Parameter fraction: Target fraction (e.g. 0.2 = 20% of current volume).
    static func lower(to fraction: Float) {
        queue.async {
            guard let deviceID = defaultOutputDevice() else { return }
            guard let current = getVolume(device: deviceID) else { return }

            // Don't lower if already very quiet
            guard current > 0.05 else { return }

            savedVolume.withLock { $0 = current }
            UserDefaults.standard.set(current, forKey: savedVolumeKey)
            let target = current * max(0, min(1, fraction))
            setVolume(device: deviceID, volume: target)
            logger.info("Volume lowered: \(current, format: .fixed(precision: 2)) → \(target, format: .fixed(precision: 2))")
        }
    }

    /// Restore volume to the level saved before lowering.
    static func restore() {
        queue.async {
            let saved: Float? = savedVolume.withLock { value in
                let v = value
                value = nil
                return v
            }
            guard let saved else { return }
            UserDefaults.standard.removeObject(forKey: savedVolumeKey)

            guard let deviceID = defaultOutputDevice() else { return }
            setVolume(device: deviceID, volume: saved)
            logger.info("Volume restored: \(saved, format: .fixed(precision: 2))")
        }
    }

    /// Restore volume from a previous session if the app crashed while volume was lowered.
    /// Call once at app launch. Runs synchronously — safe because it's before UI shows.
    static func restoreIfNeeded() {
        let saved = UserDefaults.standard.float(forKey: savedVolumeKey)
        guard saved > 0 else { return }
        UserDefaults.standard.removeObject(forKey: savedVolumeKey)

        guard let deviceID = defaultOutputDevice() else { return }
        setVolume(device: deviceID, volume: saved)
        logger.info("Crash recovery: volume restored to \(saved, format: .fixed(precision: 2))")
    }

    // MARK: - Start Sound Delay

    /// Compute the optimal delay between recording start and alert sound playback,
    /// based on whether the input and output are the same physical Bluetooth device.
    /// Mirrors the Typeless approach: same BT device → 1200ms, AirPods → 300ms,
    /// separate BT speaker → 100ms (codec wake-up), wired/built-in → 0.
    static func startSoundDelay() -> Int {
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

    private static func getVolume(device: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    private static func setVolume(device: AudioDeviceID, volume: Float) {
        var vol = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
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
