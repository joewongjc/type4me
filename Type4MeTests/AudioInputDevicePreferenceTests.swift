import CoreAudio
import XCTest
@testable import Type4Me

final class AudioInputDevicePreferenceTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.modeKey)
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.priorityEntriesKey)
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.selectedUIDKey)
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.backupUIDKey)
        UserDefaults.standard.removeObject(forKey: "tf_microphoneSelectionMode")
        UserDefaults.standard.removeObject(forKey: "tf_microphonePriorityOrder")
        AudioInputDeviceMonitor.shared.replaceCachedDevices([])
        super.tearDown()
    }

    func testCategoryUsesBluetoothTransportForMicrophoneDevices() {
        let category = AudioInputDeviceDiscovery.category(
            forName: "Li Glasses 0966",
            uid: "0C-27-56-7F-AF-B3:input",
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        XCTAssertEqual(category, .bluetooth)
    }

    func testCategoryUsesBuiltInTransportForMacMicrophone() {
        let category = AudioInputDeviceDiscovery.category(
            forName: "MacBook Pro麦克风",
            uid: "BuiltInMicrophoneDevice",
            transportType: kAudioDeviceTransportTypeBuiltIn
        )

        XCTAssertEqual(category, .builtIn)
    }

    func testCategoryUsesUSBTransportForExternalMicrophone() {
        let category = AudioInputDeviceDiscovery.category(
            forName: "Newmine",
            uid: "AppleUSBAudioEngine:Generic:Newmine:20210726905921:1",
            transportType: kAudioDeviceTransportTypeUSB
        )

        XCTAssertEqual(category, .external)
    }

    func testResolvedDeviceUsesSystemDefaultWhenModeIsSystem() {
        AudioInputDevicePreferenceStore.savePriorityEntries([
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
        ])
        AudioInputDevicePreferenceStore.resetToSystemDefault()
        let devices = [
            AudioInputDevice(uid: "airpods", name: "AirPods Pro", category: .bluetooth),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedDevice(devices: devices)

        XCTAssertNil(resolved)
        XCTAssertEqual(AudioInputDevicePreferenceStore.priorityEntries().map(\.uid), ["airpods"])
    }

    func testResolvedDeviceUsesFirstAvailablePriorityEntry() {
        AudioInputDevicePreferenceStore.savePriorityEntries([
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
            AudioInputDevicePreferenceEntry(uid: "built-in", name: "MacBook Pro Microphone"),
        ])
        let devices = [
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
            AudioInputDevice(uid: "airpods", name: "AirPods Pro", category: .bluetooth),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedDevice(devices: devices)

        XCTAssertEqual(resolved?.uid, "airpods")
    }

    func testResolvedDeviceUsesNextPriorityEntryWhenFirstUnavailable() {
        AudioInputDevicePreferenceStore.savePriorityEntries([
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
            AudioInputDevicePreferenceEntry(uid: "built-in", name: "MacBook Pro Microphone"),
        ])
        let devices = [
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedDevice(devices: devices)

        XCTAssertEqual(resolved?.uid, "built-in")
    }

    func testResolvedDeviceFallsBackToSystemDefaultWhenNoPriorityEntriesAreAvailable() {
        AudioInputDevicePreferenceStore.savePriorityEntries([
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
            AudioInputDevicePreferenceEntry(uid: "built-in", name: "MacBook Pro Microphone"),
        ])
        let devices = [
            AudioInputDevice(uid: "usb", name: "USB Microphone", category: .external),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedDevice(devices: devices)

        XCTAssertNil(resolved)
    }

    func testPriorityEntryStoragePreservesDeviceNamesAndOrder() {
        let entries = [
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
            AudioInputDevicePreferenceEntry(uid: "built-in", name: "MacBook Pro Microphone"),
        ]

        let roundTrip = AudioInputDevicePreferenceStore.priorityEntries(
            from: AudioInputDevicePreferenceStore.storageValue(for: entries)
        )

        XCTAssertEqual(roundTrip, entries)
    }

    func testPriorityEntryStorageNormalizesDuplicateUIDs() {
        let entries = [
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro 2"),
            AudioInputDevicePreferenceEntry(uid: "built-in", name: "MacBook Pro Microphone"),
        ]

        let roundTrip = AudioInputDevicePreferenceStore.priorityEntries(
            from: AudioInputDevicePreferenceStore.storageValue(for: entries)
        )

        XCTAssertEqual(roundTrip.map(\.uid), ["airpods", "built-in"])
        XCTAssertEqual(roundTrip.first?.name, "AirPods Pro")
    }

    func testCachedResolutionUsesMonitorCacheForPriorityEntries() {
        AudioInputDevicePreferenceStore.savePriorityEntries([
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
            AudioInputDevicePreferenceEntry(uid: "built-in", name: "MacBook Pro Microphone"),
        ])
        AudioInputDeviceMonitor.shared.replaceCachedDevices([
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
        ])

        let resolved = AudioInputDevicePreferenceStore.resolvedCachedDeviceUID()

        XCTAssertEqual(resolved, "built-in")
    }

    func testMigrationMapsLegacyPrimaryAndBackupToPriorityEntries() {
        UserDefaults.standard.set("airpods", forKey: AudioInputDevicePreferenceStore.selectedUIDKey)
        UserDefaults.standard.set("built-in", forKey: AudioInputDevicePreferenceStore.backupUIDKey)
        UserDefaults.standard.set("automatic", forKey: "tf_microphoneSelectionMode")
        UserDefaults.standard.set("bluetooth,builtIn", forKey: "tf_microphonePriorityOrder")

        AudioInputDevicePreferenceStore.migrateIfNeeded()

        XCTAssertEqual(AudioInputDevicePreferenceStore.mode(), .priority)
        XCTAssertEqual(AudioInputDevicePreferenceStore.priorityEntries().map(\.uid), ["airpods", "built-in"])
        XCTAssertNil(UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.selectedUIDKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.backupUIDKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: "tf_microphoneSelectionMode"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "tf_microphonePriorityOrder"))
    }

    func testMigrationSetsPriorityModeWhenPriorityEntriesAlreadyExist() {
        let entries = [
            AudioInputDevicePreferenceEntry(uid: "airpods", name: "AirPods Pro"),
        ]
        UserDefaults.standard.set(
            AudioInputDevicePreferenceStore.storageValue(for: entries),
            forKey: AudioInputDevicePreferenceStore.priorityEntriesKey
        )

        AudioInputDevicePreferenceStore.migrateIfNeeded()

        XCTAssertEqual(AudioInputDevicePreferenceStore.mode(), .priority)
        XCTAssertEqual(AudioInputDevicePreferenceStore.priorityEntries(), entries)
    }
}
