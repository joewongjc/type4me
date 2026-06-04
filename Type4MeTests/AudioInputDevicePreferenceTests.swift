import XCTest
import CoreAudio
@testable import Type4Me

final class AudioInputDevicePreferenceTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.selectionModeKey)
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.selectedUIDKey)
        UserDefaults.standard.removeObject(forKey: AudioInputDevicePreferenceStore.priorityOrderKey)
        AudioInputDeviceMonitor.shared.replaceCachedDevices([])
        super.tearDown()
    }

    func testAutomaticResolutionPrefersBluetoothWhenConfiguredFirst() {
        let devices = [
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
            AudioInputDevice(uid: "airpods", name: "AirPods Pro", category: .bluetooth),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedAutomaticDevice(
            devices: devices,
            priorityOrder: [.bluetooth, .builtIn]
        )

        XCTAssertEqual(resolved?.uid, "airpods")
    }

    func testAutomaticResolutionPrefersBuiltInWhenConfiguredFirst() {
        let devices = [
            AudioInputDevice(uid: "airpods", name: "AirPods Pro", category: .bluetooth),
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedAutomaticDevice(
            devices: devices,
            priorityOrder: [.builtIn, .bluetooth]
        )

        XCTAssertEqual(resolved?.uid, "built-in")
    }

    func testAutomaticResolutionFallsThroughPriorityOrder() {
        let devices = [
            AudioInputDevice(uid: "usb", name: "USB Microphone", category: .external),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedAutomaticDevice(
            devices: devices,
            priorityOrder: [.bluetooth, .builtIn, .external]
        )

        XCTAssertEqual(resolved?.uid, "usb")
    }

    func testPriorityOrderNormalizesDuplicatesAndMissingCategories() {
        let order = AudioInputDevicePreferenceStore.priorityOrder(from: "builtIn,bluetooth,builtIn")

        XCTAssertEqual(order.prefix(2), [.builtIn, .bluetooth])
        XCTAssertEqual(Set(order), Set(AudioInputDeviceCategory.defaultPriorityOrder))
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

    func testManualResolutionUsesSavedDeviceWhenAvailable() {
        UserDefaults.standard.set(AudioInputDeviceSelectionMode.manual.rawValue, forKey: AudioInputDevicePreferenceStore.selectionModeKey)
        UserDefaults.standard.set("usb", forKey: AudioInputDevicePreferenceStore.selectedUIDKey)
        let devices = [
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
            AudioInputDevice(uid: "usb", name: "USB Microphone", category: .external),
        ]

        let resolved = AudioInputDevicePreferenceStore.resolvedDevice(devices: devices)

        XCTAssertEqual(resolved?.uid, "usb")
    }

    func testCachedManualResolutionUsesSavedUIDWithoutDeviceList() {
        UserDefaults.standard.set(AudioInputDeviceSelectionMode.manual.rawValue, forKey: AudioInputDevicePreferenceStore.selectionModeKey)
        UserDefaults.standard.set("temporarily-unavailable", forKey: AudioInputDevicePreferenceStore.selectedUIDKey)

        let resolved = AudioInputDevicePreferenceStore.resolvedCachedDeviceUID()

        XCTAssertEqual(resolved, "temporarily-unavailable")
    }

    func testCachedAutomaticResolutionUsesMonitorCache() {
        UserDefaults.standard.set(AudioInputDeviceSelectionMode.automatic.rawValue, forKey: AudioInputDevicePreferenceStore.selectionModeKey)
        AudioInputDeviceMonitor.shared.replaceCachedDevices([
            AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", category: .builtIn),
            AudioInputDevice(uid: "bluetooth", name: "Li Glasses 0966", category: .bluetooth),
        ])

        let resolved = AudioInputDevicePreferenceStore.resolvedCachedDeviceUID()

        XCTAssertEqual(resolved, "bluetooth")
    }

    func testMigrationPreservesLegacySelectedMicrophoneAsManualMode() {
        UserDefaults.standard.set("legacy-mic", forKey: AudioInputDevicePreferenceStore.selectedUIDKey)

        AudioInputDevicePreferenceStore.migrateIfNeeded()

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AudioInputDevicePreferenceStore.selectionModeKey),
            AudioInputDeviceSelectionMode.manual.rawValue
        )
    }
}
