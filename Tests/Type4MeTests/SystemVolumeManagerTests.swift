import CoreAudio
import XCTest
@testable import Type4Me

final class SystemVolumeManagerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SystemVolumeManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingReductionPreferenceDoesNotLowerVolume() {
        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), -1)
    }

    func testExplicitNoReductionPreferenceIsPreserved() {
        defaults.set(-1, forKey: SystemVolumeManager.volumeReductionKey)

        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), -1)
    }

    func testExplicitMutePreferenceIsPreserved() {
        defaults.set(0, forKey: SystemVolumeManager.volumeReductionKey)

        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), 0)
    }

    func testExplicitReductionPreferenceIsPreserved() {
        defaults.set(30, forKey: SystemVolumeManager.volumeReductionKey)

        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), 30)
    }
    private final class Audio: VolumeAudioAdapter {
        var current: AudioDeviceID = 1
        /// Device currently holding UID "original"; nil means disconnected.
        var original: AudioDeviceID? = 1
        /// Other connected outputs by UID.
        var others: [String: AudioDeviceID] = [:]
        var levels: [AudioDeviceID: Float] = [:]
        var failRead = false
        var failWrite = false
        var failAfterApply = false
        var readOnly = false
        var writes: [AudioDeviceID] = []
        enum Failure: Error { case unavailable }
        var level: Float {
            get { levels[current, default: 0.55] }
            set { levels[current] = newValue }
        }
        func defaultOutput() throws -> AudioDeviceID { current }
        func uid(of device: AudioDeviceID) throws -> String {
            if device == original { return "original" }
            return others.first { $0.value == device }?.key ?? "device-\(device)"
        }
        func device(for uid: String) throws -> AudioDeviceID {
            let device = uid == "original" ? original : others[uid]
            guard let device else { throw Failure.unavailable }
            return device
        }
        func volume(_ device: AudioDeviceID) throws -> Float {
            if failRead { throw Failure.unavailable }
            return levels[device, default: 0.55]
        }
        func setVolume(_ value: Float, on device: AudioDeviceID) throws {
            writes.append(device)
            if readOnly { throw VolumeAudioError.unsupportedProperty(0) }
            if failAfterApply { levels[device] = value }
            if failWrite || failAfterApply { throw Failure.unavailable }
            levels[device] = value
        }
    }

    private var queued: [() -> Void] = []
    private var delayed: [() -> Void] = []
    private var messages: [String] = []

    private func transaction(_ audio: Audio) -> VolumeRestorationTransaction {
        VolumeRestorationTransaction(defaults: defaults, audio: audio,
            enqueue: { self.queued.append($0) },
            schedule: { _, work in self.delayed.append(work) },
            log: { self.messages.append($0) })
    }

    private func drain() {
        while !queued.isEmpty { queued.removeFirst()() }
    }

    private func drainAll() {
        drain()
        while !delayed.isEmpty { delayed.removeFirst()() }
    }

    private var record: Any? { defaults.object(forKey: VolumeRestorationTransaction.recoveryKey) }

    func testRestorationDetectsClobberAndCoalescesRequests() {
        let audio = Audio()
        let manager = transaction(audio)
        let token = manager.reserveAttenuation()
        manager.lower(to: 0.2, token: token)
        manager.lower(to: 0.2, token: token)
        drain()
        XCTAssertEqual(audio.level, 0.11, accuracy: 0.0001)
        XCTAssertEqual(audio.writes.count, 1)
        manager.restore()
        manager.restore()
        drain()
        XCTAssertEqual(delayed.count, 1)
        XCTAssertNotNil(record)
        for clobber: Float in [0, 0.057] {
            audio.level = clobber // External writer fires before the delayed readback.
            delayed.removeFirst()()
            XCTAssertEqual(audio.level, 0.55, accuracy: 0.0001)
            XCTAssertFalse(messages.contains("Volume restored and verified"))
        }
        delayed.removeFirst()()
        XCTAssertNil(record)
        XCTAssertEqual(messages.filter { $0 == "Volume restored and verified" }.count, 1)
        XCTAssertTrue(delayed.isEmpty)
    }

    func testCancellationAndPendingRestorationBlockAttenuation() {
        let audio = Audio()
        let manager = transaction(audio)
        let old = manager.reserveAttenuation()
        manager.lower(to: 0.2, token: old)
        manager.restore()
        let next = manager.reserveAttenuation()
        manager.lower(to: 0.2, token: old)
        drain()
        XCTAssertTrue(audio.writes.isEmpty)
        manager.lower(to: 0.2, token: next)
        drain()
        manager.restore()
        drain()
        manager.lower(to: 0, token: manager.reserveAttenuation())
        drain()
        XCTAssertEqual(audio.writes.count, 2)
        delayed.removeFirst()()
        XCTAssertEqual(audio.level, 0.55, accuracy: 0.0001)
    }

    func testRecoveryUsesUIDAcrossRelaunchAndRetainsDisconnectedDevice() {
        let audio = Audio()
        var manager = transaction(audio)
        manager.lower(to: 0, token: manager.reserveAttenuation())
        drain()
        audio.current = 2
        audio.original = nil
        manager = transaction(audio)
        manager.restore()
        drainAll()
        XCTAssertEqual(audio.writes, [1])
        XCTAssertNotNil(record)
        audio.original = 3
        audio.levels[3] = 0
        manager.restore()
        drain()
        delayed.removeFirst()()
        XCTAssertEqual(audio.writes, [1, 3])
        XCTAssertEqual(audio.levels[3], 0.55)
        XCTAssertNil(record)
    }

    // A non-settable volume on restore is transient: retry, then restore once it is settable.
    func testTemporarilyNonSettableVolumeRestoresOriginal() {
        let audio = Audio()
        let manager = transaction(audio)
        manager.lower(to: 0.2, token: manager.reserveAttenuation())
        drain()
        XCTAssertEqual(audio.level, 0.11, accuracy: 0.0001)
        XCTAssertNotNil(record)
        audio.readOnly = true
        manager.restore()
        drain()
        XCTAssertNotNil(record)
        XCTAssertEqual(audio.level, 0.11, accuracy: 0.0001)
        audio.readOnly = false
        drainAll()
        XCTAssertEqual(audio.level, 0.55, accuracy: 0.0001)
        XCTAssertNil(record)
    }

    // A failed first write rolls the snapshot back when the device volume is unchanged.
    func testFailedInitialWriteRollsBackRecord() {
        for readOnly in [false, true] {
            let audio = Audio()
            let manager = transaction(audio)
            audio.failWrite = !readOnly
            audio.readOnly = readOnly
            manager.lower(to: 0.2, token: manager.reserveAttenuation())
            drain()
            XCTAssertEqual(audio.writes.count, 1)
            XCTAssertNil(record)
            audio.failWrite = false
            audio.readOnly = false
            manager.lower(to: 0.2, token: manager.reserveAttenuation())
            drain()
            XCTAssertEqual(audio.level, 0.11, accuracy: 0.0001)
            manager.restore()
            drainAll()
            XCTAssertEqual(audio.level, 0.55, accuracy: 0.0001)
            XCTAssertNil(record)
        }
    }

    // A write error that changes the volume keeps the record so the original can be restored.
    func testWriteErrorThatChangesVolumeRetainsRecord() {
        let audio = Audio()
        let manager = transaction(audio)
        audio.failAfterApply = true
        manager.lower(to: 0.2, token: manager.reserveAttenuation())
        drain()
        XCTAssertEqual(audio.level, 0.11, accuracy: 0.0001)
        XCTAssertNotNil(record)
        audio.failAfterApply = false
        manager.restore()
        drainAll()
        XCTAssertEqual(audio.level, 0.55, accuracy: 0.0001)
        XCTAssertNil(record)
    }

    // Review point 3: disconnect -> switch output -> reconnect.
    func testDisconnectedDeviceDoesNotBlockOtherOutputs() {
        let audio = Audio()
        audio.others = ["speakers": 2]
        audio.levels = [1: 0.6, 2: 0.8]
        let manager = transaction(audio)
        manager.lower(to: 0.5, token: manager.reserveAttenuation())
        drain()
        XCTAssertEqual(audio.levels[1]!, 0.3, accuracy: 0.0001)
        audio.original = nil
        audio.current = 2
        manager.restore()
        drainAll()
        XCTAssertNotNil(record)
        manager.lower(to: 0.5, token: manager.reserveAttenuation())
        drain()
        XCTAssertEqual(audio.levels[2]!, 0.4, accuracy: 0.0001)
        manager.restore()
        drainAll()
        XCTAssertEqual(audio.levels[2]!, 0.8, accuracy: 0.0001)
        XCTAssertNotNil(record)
        audio.original = 1
        manager.restore()
        drainAll()
        XCTAssertEqual(audio.levels[1]!, 0.6, accuracy: 0.0001)
        XCTAssertNil(record)
    }

    // Review point 4: undecodable records are cleared instead of blocking attenuation forever.
    func testUndecodableRecordsAreClearedAndLegacyZeroIsVerified() {
        let audio = Audio()
        let manager = transaction(audio)
        defaults.set(Data("invalid".utf8), forKey: VolumeRestorationTransaction.recoveryKey)
        defaults.set("invalid", forKey: VolumeRestorationTransaction.legacyKey)
        manager.restore()
        drainAll()
        XCTAssertTrue(audio.writes.isEmpty)
        XCTAssertNil(record)
        XCTAssertNil(defaults.object(forKey: VolumeRestorationTransaction.legacyKey))
        manager.lower(to: 0.2, token: manager.reserveAttenuation())
        drain()
        XCTAssertEqual(audio.level, 0.11, accuracy: 0.0001)
        manager.restore()
        drainAll()
        audio.writes = []
        defaults.set(Float(0), forKey: VolumeRestorationTransaction.legacyKey)
        manager.restore()
        drain()
        XCTAssertNotNil(defaults.object(forKey: VolumeRestorationTransaction.legacyKey))
        XCTAssertEqual(audio.level, 0)
        delayed.removeFirst()()
        XCTAssertNil(defaults.object(forKey: VolumeRestorationTransaction.legacyKey))
    }

    // Review point 5: outputs at or below 5% are left alone.
    func testVeryQuietOutputIsLeftAlone() {
        for level: Float in [0, 0.04, 0.05] {
            let audio = Audio()
            audio.level = level
            let manager = transaction(audio)
            manager.lower(to: 0.2, token: manager.reserveAttenuation())
            drain()
            XCTAssertTrue(audio.writes.isEmpty)
            XCTAssertEqual(audio.level, level)
            XCTAssertNil(record)
        }
    }

    func testTransientFailuresRetainRecoveryAndNeverReportSuccess() {
        let audio = Audio()
        let manager = transaction(audio)
        audio.failRead = true
        manager.lower(to: 0, token: manager.reserveAttenuation())
        drain()
        XCTAssertTrue(audio.writes.isEmpty)
        audio.failRead = false
        manager.lower(to: 0, token: manager.reserveAttenuation())
        drain()
        audio.failWrite = true
        manager.restore()
        drainAll()
        XCTAssertEqual(audio.writes.count, 4)
        XCTAssertNotNil(record)
        audio.failWrite = false
        audio.failRead = true
        manager.restore()
        drainAll()
        XCTAssertNotNil(record)
        XCTAssertFalse(messages.contains("Volume restored and verified"))
    }

}
