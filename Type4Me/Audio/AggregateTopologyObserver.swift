import CoreAudio
import Foundation

/// Watches one aggregate device's sub-device composition so a prepared
/// capture graph is dropped before a Bluetooth sub-device can pin HFP.
final class AggregateTopologyObserver: @unchecked Sendable {
    let aggregateUID: String
    private let deviceID: AudioDeviceID
    private let queue: DispatchQueue
    private let onChange: () -> Void

    private var isInvalidated = false
    private let lock = NSLock()

    private var activeListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init?(aggregateUID: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.aggregateUID = aggregateUID
        self.queue = queue
        self.onChange = onChange

        guard let deviceID = AudioInputDeviceDiscovery.coreAudioDeviceID(forUID: aggregateUID) else {
            return nil
        }
        self.deviceID = deviceID

        let selectors: [AudioObjectPropertySelector] = [
            kAudioAggregateDevicePropertyActiveSubDeviceList,
            kAudioAggregateDevicePropertyFullSubDeviceList,
            kAudioAggregateDevicePropertyComposition
        ]

        var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        var allSucceeded = true

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.lock.withLock {
                    guard !self.isInvalidated else { return }
                    self.onChange()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
            if status == noErr {
                registered.append((address, block))
            } else {
                allSucceeded = false
                break
            }
        }

        guard allSucceeded else {
            // Rollback any successfully registered listeners
            for (var addr, blk) in registered {
                AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, blk)
            }
            return nil
        }

        self.activeListeners = registered
    }

    /// Internal init for unit testing with mock listener hooks
    init(testAggregateUID: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.aggregateUID = testAggregateUID
        self.deviceID = 0
        self.queue = queue
        self.onChange = onChange
    }

    /// Triggers the change callback manually (primarily for testing).
    func triggerChangeForTesting() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard !self.isInvalidated else { return }
                self.onChange()
            }
        }
    }

    func invalidate() {
        lock.withLock {
            guard !isInvalidated else { return }
            isInvalidated = true
            for (var address, block) in activeListeners {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
            }
            activeListeners.removeAll()
        }
    }

    deinit {
        invalidate()
    }
}
