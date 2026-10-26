import XCTest
import CoreAudio
@testable import Type4Me

/// Records every listener call so tests can compare registration and removal arguments.
private final class ListenerCallRecorder: @unchecked Sendable {
    struct Call {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement
        let queue: DispatchQueue
        let block: AnyObject
    }

    private let lock = NSLock()
    private var _adds: [Call] = []
    private var _removes: [Call] = []
    /// Addresses whose registration should fail, keyed by "selector:scope".
    var failingAdds: Set<String> = []

    var adds: [Call] { lock.withLock { _adds } }
    var removes: [Call] { lock.withLock { _removes } }

    var api: CoreAudioListenerAPI {
        CoreAudioListenerAPI(
            add: { [self] objectID, address, queue, block in
                let call = Self.call(objectID, address, queue, block)
                lock.withLock { _adds.append(call) }
                return failingAdds.contains("\(address.mSelector):\(address.mScope)")
                    ? OSStatus(kAudioHardwareUnknownPropertyError)
                    : noErr
            },
            remove: { [self] objectID, address, queue, block in
                let call = Self.call(objectID, address, queue, block)
                lock.withLock { _removes.append(call) }
                return noErr
            }
        )
    }

    private static func call(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ queue: DispatchQueue,
        _ block: @escaping CoreAudioListenerBlock
    ) -> Call {
        Call(
            objectID: objectID,
            selector: address.mSelector,
            scope: address.mScope,
            element: address.mElement,
            queue: queue,
            block: block as AnyObject
        )
    }
}

final class CoreAudioOutputRouteMonitorTests: XCTestCase {
    private let deviceID: AudioDeviceID = 42

    func testRemovalUsesExactlyTheRegistrationArguments() throws {
        let recorder = ListenerCallRecorder()
        let monitor = CoreAudioOutputRouteMonitor(listenerAPI: recorder.api)
        let queue = DispatchQueue(label: "test.route.queue")

        let token = try XCTUnwrap(monitor.addRouteChangeListener(for: deviceID, queue: queue) { _ in })
        monitor.removeRouteChangeListener(token)

        let adds = recorder.adds
        let removes = recorder.removes
        XCTAssertEqual(adds.count, 4)
        XCTAssertEqual(removes.count, adds.count)
        for (add, remove) in zip(adds, removes) {
            XCTAssertEqual(remove.objectID, add.objectID)
            XCTAssertEqual(remove.selector, add.selector)
            XCTAssertEqual(remove.scope, add.scope)
            XCTAssertEqual(remove.element, add.element)
            XCTAssertTrue(remove.queue === queue, "removal must pass the registration queue, not nil")
            XCTAssertTrue(remove.block === add.block, "removal must pass the registered block")
        }
    }

    func testOnlySuccessfullyRegisteredAddressesAreRemoved() throws {
        let recorder = ListenerCallRecorder()
        recorder.failingAdds = ["\(kAudioDevicePropertyStreamFormat):\(kAudioObjectPropertyScopeGlobal)"]
        let monitor = CoreAudioOutputRouteMonitor(listenerAPI: recorder.api)

        let token = try XCTUnwrap(monitor.addRouteChangeListener(for: deviceID, queue: .main) { _ in })
        monitor.removeRouteChangeListener(token)

        XCTAssertEqual(recorder.adds.count, 4)
        XCTAssertEqual(recorder.removes.count, 3)
        XCTAssertFalse(recorder.removes.contains {
            $0.selector == kAudioDevicePropertyStreamFormat && $0.scope == kAudioObjectPropertyScopeGlobal
        })
    }

    func testNoTokenWhenEveryRegistrationFails() {
        let recorder = ListenerCallRecorder()
        recorder.failingAdds = [
            "\(kAudioDevicePropertyNominalSampleRate):\(kAudioObjectPropertyScopeOutput)",
            "\(kAudioDevicePropertyNominalSampleRate):\(kAudioObjectPropertyScopeGlobal)",
            "\(kAudioDevicePropertyStreamFormat):\(kAudioObjectPropertyScopeOutput)",
            "\(kAudioDevicePropertyStreamFormat):\(kAudioObjectPropertyScopeGlobal)",
        ]
        let monitor = CoreAudioOutputRouteMonitor(listenerAPI: recorder.api)

        XCTAssertNil(monitor.addRouteChangeListener(for: deviceID, queue: .main) { _ in })
        XCTAssertTrue(recorder.removes.isEmpty)
    }

    func testRepeatedRemovalUnregistersOnlyOnce() throws {
        let recorder = ListenerCallRecorder()
        let monitor = CoreAudioOutputRouteMonitor(listenerAPI: recorder.api)

        let token = try XCTUnwrap(monitor.addRouteChangeListener(for: deviceID, queue: .main) { _ in })
        monitor.removeRouteChangeListener(token)
        monitor.removeRouteChangeListener(token)

        XCTAssertEqual(recorder.removes.count, 4)
    }

    /// Against real CoreAudio: after removal the listener must stop firing. A status
    /// check cannot prove this because removal reports noErr even when nothing matched.
    func testListenerBlocksHelperActuallyRemovesListener() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Per-process input mute: toggling it affects only this test process.
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessInputMute,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = DispatchQueue(label: "test.listener.removal")
        let lock = NSLock()
        var hits = 0
        let block: CoreAudioListenerBlock = { _, _ in lock.withLock { hits += 1 } }

        func toggleMute() throws {
            for value: UInt32 in [1, 0] {
                var value = value
                var mutableAddress = address
                let status = AudioObjectSetPropertyData(
                    system, &mutableAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
                )
                guard status == noErr else { throw XCTSkip("process input mute unavailable: \(status)") }
                Thread.sleep(forTimeInterval: 0.15)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertEqual(CoreAudioListenerBlocks.add(system, address, queue, block), noErr)
        try toggleMute()
        let hitsWhileRegistered = lock.withLock { hits }
        XCTAssertGreaterThan(hitsWhileRegistered, 0, "listener should fire while registered")

        XCTAssertEqual(CoreAudioListenerBlocks.remove(system, address, queue, block), noErr)
        try toggleMute()
        XCTAssertEqual(lock.withLock { hits }, hitsWhileRegistered, "listener kept firing after removal")
    }
}
