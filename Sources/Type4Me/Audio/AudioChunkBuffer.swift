import Foundation

/// Thread-safe buffer for audio chunks during ASR connection setup.
/// Collects chunks from AudioCaptureEngine while WebSocket is connecting,
/// then drains them for replay once the connection is established.
final class AudioChunkBuffer: @unchecked Sendable {
    private var chunks: [Data] = []
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.withLock { chunks.append(data) }
    }

    /// Remove and return all buffered chunks.
    func drain() -> [Data] {
        lock.withLock {
            let result = chunks
            chunks.removeAll()
            return result
        }
    }
}
