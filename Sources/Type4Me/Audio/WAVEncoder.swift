import Foundation

enum WAVEncoder {
    /// Wrap raw PCM data in a 44-byte standard RIFF WAV header (PCM format, little-endian).
    static func encode(
        pcmData: Data,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var wav = Data(capacity: 44 + pcmData.count)
        wav.append(contentsOf: "RIFF".utf8)
        appendUInt32(&wav, fileSize)
        wav.append(contentsOf: "WAVE".utf8)

        wav.append(contentsOf: "fmt ".utf8)
        appendUInt32(&wav, 16)
        appendUInt16(&wav, 1) // PCM format
        appendUInt16(&wav, UInt16(channels))
        appendUInt32(&wav, UInt32(sampleRate))
        appendUInt32(&wav, UInt32(byteRate))
        appendUInt16(&wav, UInt16(blockAlign))
        appendUInt16(&wav, UInt16(bitsPerSample))

        wav.append(contentsOf: "data".utf8)
        appendUInt32(&wav, dataSize)
        wav.append(pcmData)

        return wav
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }
}
