import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum AudioInputDeviceCategory: String, CaseIterable, Codable, Equatable {
    case bluetooth
    case builtIn
    case external
    case virtual
    case other

    var displayName: String {
        switch self {
        case .bluetooth:
            return L("蓝牙设备", "Bluetooth")
        case .builtIn:
            return L("内置麦克风", "Built-in")
        case .external:
            return L("外接/USB", "External/USB")
        case .virtual:
            return L("虚拟设备", "Virtual")
        case .other:
            return L("其他设备", "Other")
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let name: String
    let category: AudioInputDeviceCategory
}

enum AudioInputDevicePreferenceMode: String {
    case systemDefault
    case priority
}

struct AudioInputDevicePreferenceEntry: Codable, Equatable, Identifiable {
    var id: String { uid }
    let uid: String
    let name: String
}

enum AudioInputDevicePreferenceStore {
    static let modeKey = "tf_microphonePreferenceMode"
    static let priorityEntriesKey = "tf_microphonePriorityEntries"

    static let selectedUIDKey = "tf_selectedMicrophoneUID"
    static let backupUIDKey = "tf_backupMicrophoneUID"
    private static let obsoleteSelectionModeKey = "tf_microphoneSelectionMode"
    private static let obsoletePriorityOrderKey = "tf_microphonePriorityOrder"

    static func migrateIfNeeded() {
        if UserDefaults.standard.object(forKey: modeKey) == nil {
            let storedEntries = priorityEntries(from: UserDefaults.standard.string(forKey: priorityEntriesKey))
            if !storedEntries.isEmpty {
                UserDefaults.standard.set(AudioInputDevicePreferenceMode.priority.rawValue, forKey: modeKey)
            } else {
                let legacyEntries = [
                    legacyEntry(forKey: selectedUIDKey),
                    legacyEntry(forKey: backupUIDKey),
                ].compactMap { $0 }

                if legacyEntries.isEmpty {
                    UserDefaults.standard.set(AudioInputDevicePreferenceMode.systemDefault.rawValue, forKey: modeKey)
                } else {
                    savePriorityEntries(legacyEntries)
                }
            }
        }

        UserDefaults.standard.removeObject(forKey: selectedUIDKey)
        UserDefaults.standard.removeObject(forKey: backupUIDKey)
        UserDefaults.standard.removeObject(forKey: obsoleteSelectionModeKey)
        UserDefaults.standard.removeObject(forKey: obsoletePriorityOrderKey)
    }

    static func resolvedDeviceUID(devices: [AudioInputDevice] = AudioInputDeviceDiscovery.availableInputDevices()) -> String? {
        resolvedDevice(devices: devices)?.uid
    }

    static func resolvedCachedDeviceUID() -> String? {
        let devices = cachedDevicesOrRefresh()
        return resolvedDevice(devices: devices)?.uid
    }

    static func mode() -> AudioInputDevicePreferenceMode {
        migrateIfNeeded()
        let rawValue = UserDefaults.standard.string(forKey: modeKey)
        return rawValue.flatMap(AudioInputDevicePreferenceMode.init(rawValue:)) ?? .systemDefault
    }

    static func priorityEntries() -> [AudioInputDevicePreferenceEntry] {
        migrateIfNeeded()
        return priorityEntries(from: UserDefaults.standard.string(forKey: priorityEntriesKey))
    }

    static func priorityEntries(from rawValue: String?) -> [AudioInputDevicePreferenceEntry] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        if let data = rawValue.data(using: .utf8),
           let entries = try? JSONDecoder().decode([AudioInputDevicePreferenceEntry].self, from: data) {
            return normalizedEntries(entries)
        }

        let legacyEntries = rawValue
            .split(separator: ",")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { AudioInputDevicePreferenceEntry(uid: $0, name: $0) }
        return normalizedEntries(legacyEntries)
    }

    static func storageValue(for entries: [AudioInputDevicePreferenceEntry]) -> String {
        let normalized = normalizedEntries(entries)
        guard let data = try? JSONEncoder().encode(normalized) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func savePriorityEntries(_ entries: [AudioInputDevicePreferenceEntry]) {
        let normalized = normalizedEntries(entries)
        guard !normalized.isEmpty else {
            resetToSystemDefault(clearPriority: true)
            return
        }
        UserDefaults.standard.set(AudioInputDevicePreferenceMode.priority.rawValue, forKey: modeKey)
        UserDefaults.standard.set(storageValue(for: normalized), forKey: priorityEntriesKey)
    }

    static func resetToSystemDefault(clearPriority: Bool = false) {
        UserDefaults.standard.set(AudioInputDevicePreferenceMode.systemDefault.rawValue, forKey: modeKey)
        if clearPriority {
            UserDefaults.standard.removeObject(forKey: priorityEntriesKey)
        }
    }

    static func resolvedDevice(devices: [AudioInputDevice]) -> AudioInputDevice? {
        guard mode() == .priority else {
            return nil
        }
        return resolvedDevice(devices: devices, priorityEntries: priorityEntries())
    }

    static func resolvedDevice(
        devices: [AudioInputDevice],
        priorityEntries: [AudioInputDevicePreferenceEntry]
    ) -> AudioInputDevice? {
        for entry in normalizedEntries(priorityEntries) {
            if let device = devices.first(where: { $0.uid == entry.uid }) {
                return device
            }
        }
        return nil
    }

    private static func cachedDevicesOrRefresh() -> [AudioInputDevice] {
        let cached = AudioInputDeviceMonitor.shared.currentDevices()
        if !cached.isEmpty {
            return cached
        }
        return AudioInputDeviceMonitor.shared.refreshSynchronously()
    }

    private static func legacyEntry(forKey key: String) -> AudioInputDevicePreferenceEntry? {
        guard let uid = UserDefaults.standard.string(forKey: key), !uid.isEmpty else {
            return nil
        }
        return AudioInputDevicePreferenceEntry(uid: uid, name: uid)
    }

    private static func normalizedEntries(_ entries: [AudioInputDevicePreferenceEntry]) -> [AudioInputDevicePreferenceEntry] {
        var seen = Set<String>()
        var result: [AudioInputDevicePreferenceEntry] = []
        for entry in entries {
            let uid = entry.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, !seen.contains(uid) else { continue }
            seen.insert(uid)
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(AudioInputDevicePreferenceEntry(uid: uid, name: name.isEmpty ? uid : name))
        }
        return result
    }
}

enum AudioInputDeviceDiscovery {
    static func availableInputDevices() -> [AudioInputDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices.map {
            AudioInputDevice(
                uid: $0.uniqueID,
                name: $0.localizedName,
                category: category(for: $0)
            )
        }
    }

    private static func category(for device: AVCaptureDevice) -> AudioInputDeviceCategory {
        let transport = coreAudioDeviceID(forUID: device.uniqueID).map { transportType(device: $0) }
        return category(forName: device.localizedName, uid: device.uniqueID, transportType: transport)
    }

    static func category(forName deviceName: String, uid: String, transportType: UInt32?) -> AudioInputDeviceCategory {
        let name = deviceName.lowercased()
        if name.contains("airpods") || name.contains("bluetooth") || name.contains("蓝牙") {
            return .bluetooth
        }

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return .virtual
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire:
            return .external
        case .some:
            return .other
        case .none:
            if uid == "BuiltInMicrophoneDevice" || name.contains("macbook") || name.contains("内置") {
                return .builtIn
            }
            return .external
        }
    }

    private static func coreAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        return deviceIDs.first { deviceUID($0) == uid }
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    private static func transportType(device: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        guard status == noErr else { return 0 }
        return transport
    }
}

extension Notification.Name {
    static let audioInputDevicesDidChange = Notification.Name("Type4MeAudioInputDevicesDidChange")
}

final class AudioInputDeviceMonitor {
    static let shared = AudioInputDeviceMonitor()

    private let queue = DispatchQueue(label: "com.type4me.audio.input-devices", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var cachedDevices: [AudioInputDevice] = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        refreshSynchronously()
        addListener(selector: kAudioHardwarePropertyDevices)
        addListener(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func currentDevices() -> [AudioInputDevice] {
        lock.lock()
        defer { lock.unlock() }
        return cachedDevices
    }

    func replaceCachedDevices(_ devices: [AudioInputDevice]) {
        lock.lock()
        cachedDevices = devices
        lock.unlock()
    }

    private func addListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue
        ) { _, _ in
            self.refreshAsynchronously()
        }
    }

    @discardableResult
    func refreshSynchronously() -> [AudioInputDevice] {
        let devices = AudioInputDeviceDiscovery.availableInputDevices()
        replaceCachedDevices(devices)
        return devices
    }

    private func refreshAsynchronously() {
        let devices = AudioInputDeviceDiscovery.availableInputDevices()
        replaceCachedDevices(devices)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .audioInputDevicesDidChange, object: nil)
        }
    }
}
