import CoreAudio
import Darwin
import Foundation

/// A CoreAudio property listener block that keeps its identity across calls.
typealias CoreAudioListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

/// Registers and removes CoreAudio block listeners with a stable block object.
///
/// Swift imports `AudioObjectPropertyListenerBlock` as a native closure type, so
/// every call to `AudioObjectAddPropertyListenerBlock` / `...Remove...` bridges a
/// brand-new block. Removal then never matches the registration and the listener
/// stays installed (verified on macOS 27 with a per-process property). Calling the
/// C symbols through an explicit block signature passes the same block object to
/// both calls. Removal must also pass the queue used at registration.
enum CoreAudioListenerBlocks {
    private typealias ListenerFunction = @convention(c) (
        AudioObjectID,
        UnsafePointer<AudioObjectPropertyAddress>,
        DispatchQueue?,
        CoreAudioListenerBlock
    ) -> OSStatus

    private static let addFunction: ListenerFunction = resolve("AudioObjectAddPropertyListenerBlock")
    private static let removeFunction: ListenerFunction = resolve("AudioObjectRemovePropertyListenerBlock")

    static func add(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ queue: DispatchQueue,
        _ block: CoreAudioListenerBlock
    ) -> OSStatus {
        var address = address
        return addFunction(objectID, &address, queue, block)
    }

    /// CoreAudio reports `noErr` even when nothing matched, so a successful status
    /// does not prove removal; matching object, address, queue and block does.
    static func remove(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ queue: DispatchQueue,
        _ block: CoreAudioListenerBlock
    ) -> OSStatus {
        var address = address
        return removeFunction(objectID, &address, queue, block)
    }

    private static func resolve(_ symbol: String) -> ListenerFunction {
        guard let handle = dlopen(nil, RTLD_NOW), let pointer = dlsym(handle, symbol) else {
            fatalError("CoreAudio symbol \(symbol) is unavailable")
        }
        return unsafeBitCast(pointer, to: ListenerFunction.self)
    }
}
