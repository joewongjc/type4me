import Foundation

// MARK: - Enums

enum VolcMessageType: UInt8, Sendable {
    case fullClientRequest = 0b0001
    case audioOnlyRequest  = 0b0010
    case serverResponse    = 0b1001
    case serverError       = 0b1111
}

enum VolcMessageFlags: UInt8, Sendable {
    case noSequence              = 0b0000
    case positiveSequence        = 0b0001
    case lastPacketNoSequence    = 0b0010
    case negativeSequenceLast    = 0b0011
    case asyncFinal              = 0b0100  // bigmodel_async endpoint final response

    /// Whether the header is followed by a 4-byte sequence number.
    var hasSequence: Bool {
        self == .positiveSequence || self == .negativeSequenceLast
    }
}

enum VolcSerialization: UInt8, Sendable {
    case none = 0b0000
    case json = 0b0001
}

enum VolcCompression: UInt8, Sendable {
    case none = 0b0000
    case gzip = 0b0001
}

// MARK: - Header

struct VolcHeader: Sendable, Equatable {
    var version: UInt8 = 0b0001
    var headerSize: UInt8 = 0b0001  // 1 unit = 4 bytes
    var messageType: VolcMessageType
    var flags: VolcMessageFlags
    var serialization: VolcSerialization
    var compression: VolcCompression
    var reserved: UInt8 = 0x00

    // Encode to 4 bytes
    func encode() -> Data {
        var data = Data(count: 4)
        data[0] = (version << 4) | (headerSize & 0x0F)
        data[1] = (messageType.rawValue << 4) | (flags.rawValue & 0x0F)
        data[2] = (serialization.rawValue << 4) | (compression.rawValue & 0x0F)
        data[3] = reserved
        return data
    }

    // Decode from 4 bytes
    static func decode(from data: Data) throws -> VolcHeader {
        guard data.count >= 4 else {
            throw VolcProtocolError.headerTooShort
        }
        let byte0 = data[data.startIndex]
        let byte1 = data[data.startIndex + 1]
        let byte2 = data[data.startIndex + 2]
        let byte3 = data[data.startIndex + 3]

        let version = (byte0 >> 4) & 0x0F
        let headerSize = byte0 & 0x0F
        let msgTypeRaw = (byte1 >> 4) & 0x0F
        let flagsRaw = byte1 & 0x0F
        let serRaw = (byte2 >> 4) & 0x0F
        let compRaw = byte2 & 0x0F

        guard let messageType = VolcMessageType(rawValue: msgTypeRaw) else {
            throw VolcProtocolError.unknownMessageType(msgTypeRaw)
        }
        guard let flags = VolcMessageFlags(rawValue: flagsRaw) else {
            throw VolcProtocolError.unknownFlags(flagsRaw)
        }
        guard let serialization = VolcSerialization(rawValue: serRaw) else {
            throw VolcProtocolError.unknownSerialization(serRaw)
        }
        guard let compression = VolcCompression(rawValue: compRaw) else {
            throw VolcProtocolError.unknownCompression(compRaw)
        }

        return VolcHeader(
            version: version,
            headerSize: headerSize,
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression,
            reserved: byte3
        )
    }
}

// MARK: - Errors

enum VolcProtocolError: Error, Sendable {
    case headerTooShort
    case unknownMessageType(UInt8)
    case unknownFlags(UInt8)
    case unknownSerialization(UInt8)
    case unknownCompression(UInt8)
    case invalidPayload
    case decompressionFailed
    case compressionFailed
    case serverError(code: Int?, message: String?)
}

extension VolcProtocolError: LocalizedError {
    /// The session surfaces errors through `LocalizedError`, so a server error
    /// without this conformance reaches the user as Foundation's generic
    /// "operation couldn't be completed" and the server's own wording — the
    /// only actionable part — is lost (issue #290).
    var errorDescription: String? {
        guard case .serverError(let code, let message) = self else { return nil }
        let base = message ?? L("语音识别服务返回错误", "The speech service returned an error")
        return code.map { "\(base) (\($0))" } ?? base
    }
}

/// An error the server reported about the account or the request itself —
/// quota, billing, authentication, rate limiting.
///
/// These are worth separating from dropped sockets: retrying the same provider
/// cannot clear them, so the recovery path burns attempts on a request that
/// will keep failing while hiding the one message that says what to fix.
protocol TerminalASRError: Error {
    var isTerminalServerError: Bool { get }
}

extension VolcProtocolError: TerminalASRError {
    var isTerminalServerError: Bool {
        if case .serverError = self { return true }
        return false
    }
}
