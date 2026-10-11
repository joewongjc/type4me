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
        var original: AudioDeviceID? = 1
        var level: Float = 0.55
        var muted: Bool? = false
        var failMuteRead = false
        var failRead = false
        var failWrite = false
        var writes: [AudioDeviceID] = []
        enum Failure: Error { case unavailable }
        func defaultOutput() throws -> AudioDeviceID { current }
        func uid(of device: AudioDeviceID) throws -> String { "original" }
        func device(for uid: String) throws -> AudioDeviceID {
            guard let original else { throw Failure.unavailable }
            return original
        }
        func volume(_ device: AudioDeviceID) throws -> Float {
            if failRead { throw Failure.unavailable }
            return level
        }
        func mute(_ device: AudioDeviceID) throws -> Bool? {
            if failMuteRead || failRead { throw Failure.unavailable }
            return muted
        }
        func setVolume(_ value: Float, on device: AudioDeviceID) throws {
            writes.append(device)
            if failWrite { throw Failure.unavailable }
            level = value
        }
        func setMute(_ value: Bool, on device: AudioDeviceID) throws {
            if failWrite { throw Failure.unavailable }
            muted = value
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
        XCTAssertNotNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
        for clobber: Float in [0, 0.057] {
            audio.level = clobber // External writer fires before the delayed readback.
            delayed.removeFirst()()
            XCTAssertEqual(audio.level, 0.55, accuracy: 0.0001)
            XCTAssertFalse(messages.contains("Volume restored and verified"))
        }
        delayed.removeFirst()()
        XCTAssertNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
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
        drain()
        while !delayed.isEmpty { delayed.removeFirst()() }
        XCTAssertEqual(audio.writes, [1])
        XCTAssertNotNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
        audio.original = 3
        manager.restore()
        drain()
        delayed.removeFirst()()
        XCTAssertEqual(audio.writes, [1, 3])
        XCTAssertNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
    }

    func testMuteAndZeroSnapshotsArePreserved() {
        for mute: Bool? in [true, false, nil] {
            let audio = Audio()
            audio.level = 0
            audio.muted = mute
            let manager = transaction(audio)
            manager.lower(to: 0, token: manager.reserveAttenuation())
            drain()
            XCTAssertEqual(audio.muted, mute)
            if mute != nil { audio.muted = !(mute!) }
            manager.restore()
            drain()
            delayed.removeFirst()()
            XCTAssertEqual(audio.muted, mute)
            XCTAssertNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
        }
    }

    func testFailuresRetainRecoveryAndNeverReportSuccess() {
        let audio = Audio()
        let manager = transaction(audio)
        audio.failMuteRead = true
        manager.lower(to: 0, token: manager.reserveAttenuation())
        drain()
        XCTAssertTrue(audio.writes.isEmpty)
        audio.failMuteRead = false
        audio.failWrite = true
        manager.lower(to: 0, token: manager.reserveAttenuation())
        drain()
        manager.restore()
        drain()
        while !delayed.isEmpty { delayed.removeFirst()() }
        XCTAssertEqual(audio.writes.count, 4)
        XCTAssertNotNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
        audio.failWrite = false
        audio.failRead = true
        manager.restore()
        drain()
        while !delayed.isEmpty { delayed.removeFirst()() }
        XCTAssertNotNil(defaults.object(forKey: VolumeRestorationTransaction.recoveryKey))
        XCTAssertFalse(messages.contains("Volume restored and verified"))
    }

    func testCorruptRecordsDoNotWriteAndLegacyZeroIsVerified() {
        let audio = Audio()
        let manager = transaction(audio)
        defaults.set(Data("invalid".utf8), forKey: VolumeRestorationTransaction.recoveryKey)
        manager.restore()
        drain()
        XCTAssertTrue(audio.writes.isEmpty)
        defaults.removeObject(forKey: VolumeRestorationTransaction.recoveryKey)
        defaults.set(Float(0), forKey: VolumeRestorationTransaction.legacyKey)
        manager.restore()
        drain()
        XCTAssertNotNil(defaults.object(forKey: VolumeRestorationTransaction.legacyKey))
        XCTAssertEqual(audio.level, 0)
        delayed.removeFirst()()
        XCTAssertNil(defaults.object(forKey: VolumeRestorationTransaction.legacyKey))
    }

}
