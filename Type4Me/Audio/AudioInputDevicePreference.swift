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

    static let defaultPriorityOrder: [AudioInputDeviceCategory] = [
        .bluetooth,
        .builtIn,
        .external,
        .virtual,
        .other,
    ]

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

enum AudioInputDeviceSelectionMode: String, CaseIterable {
    case systemDefault
    case automatic
    case manual

    var displayName: String {
        switch self {
        case .systemDefault:
            return L("系统默认", "System")
        case .automatic:
            return L("自动优先级", "Auto")
        case .manual:
            return L("固定设备", "Manual")
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let name: String
    let category: AudioInputDeviceCategory
}

enum AudioInputDevicePreferenceStore {
    static let selectionModeKey = "tf_microphoneSelectionMode"
    static let selectedUIDKey = "tf_selectedMicrophoneUID"
    static let priorityOrderKey = "tf_microphonePriorityOrder"
    static let defaultPriorityOrderStorageValue = storageValue(for: AudioInputDeviceCategory.defaultPriorityOrder)

    static func migrateIfNeeded() {
        guard UserDefaults.standard.object(forKey: selectionModeKey) == nil else { return }
        let selectedUID = UserDefaults.standard.string(forKey: selectedUIDKey) ?? ""
        let mode: AudioInputDeviceSelectionMode = selectedUID.isEmpty ? .systemDefault : .manual
        UserDefaults.standard.set(mode.rawValue, forKey: selectionModeKey)
    }

    static func selectionMode() -> AudioInputDeviceSelectionMode {
        migrateIfNeeded()
        let rawValue = UserDefaults.standard.string(forKey: selectionModeKey)
        return rawValue.flatMap(AudioInputDeviceSelectionMode.init(rawValue:)) ?? .systemDefault
    }

    static func priorityOrder() -> [AudioInputDeviceCategory] {
        priorityOrder(from: UserDefaults.standard.string(forKey: priorityOrderKey))
    }

    static func priorityOrder(from rawValue: String?) -> [AudioInputDeviceCategory] {
        let parsed = (rawValue ?? "")
            .split(separator: ",")
            .compactMap { AudioInputDeviceCategory(rawValue: String($0)) }
        return normalizedPriorityOrder(parsed)
    }

    static func storageValue(for order: [AudioInputDeviceCategory]) -> String {
        normalizedPriorityOrder(order)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func resolvedDeviceUID(devices: [AudioInputDevice] = AudioInputDeviceDiscovery.availableInputDevices()) -> String? {
        resolvedDevice(devices: devices)?.uid
    }

    static func resolvedCachedDeviceUID() -> String? {
        switch selectionMode() {
        case .systemDefault:
            return nil
        case .manual:
            let selectedUID = UserDefaults.standard.string(forKey: selectedUIDKey) ?? ""
            return selectedUID.isEmpty ? nil : selectedUID
        case .automatic:
            let order = priorityOrder()
            if let cached = resolvedAutomaticDevice(
                devices: AudioInputDeviceMonitor.shared.currentDevices(),
                priorityOrder: order
            ) {
                return cached.uid
            }
            return resolvedAutomaticDevice(
                devices: AudioInputDeviceMonitor.shared.refreshSynchronously(),
                priorityOrder: order
            )?.uid
        }
    }

    static func resolvedDevice(devices: [AudioInputDevice]) -> AudioInputDevice? {
        switch selectionMode() {
        case .systemDefault:
            return nil
        case .manual:
            let selectedUID = UserDefaults.standard.string(forKey: selectedUIDKey) ?? ""
            return devices.first { $0.uid == selectedUID }
        case .automatic:
            return resolvedAutomaticDevice(devices: devices, priorityOrder: priorityOrder())
        }
    }

    static func resolvedAutomaticDevice(
        devices: [AudioInputDevice],
        priorityOrder: [AudioInputDeviceCategory]
    ) -> AudioInputDevice? {
        let order = normalizedPriorityOrder(priorityOrder)
        for category in order {
            if let device = devices.first(where: { $0.category == category }) {
                return device
            }
        }
        return nil
    }

    private static func normalizedPriorityOrder(_ order: [AudioInputDeviceCategory]) -> [AudioInputDeviceCategory] {
        var result: [AudioInputDeviceCategory] = []
        for category in order where !result.contains(category) {
            result.append(category)
        }
        for category in AudioInputDeviceCategory.defaultPriorityOrder where !result.contains(category) {
            result.append(category)
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
