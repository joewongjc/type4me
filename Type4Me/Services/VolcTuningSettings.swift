import Foundation

/// Experimental, user-adjustable knobs for the Volcano streaming session.
///
/// Every default reproduces the shipped behavior, so an untouched (or reset)
/// panel sends exactly the same request and waits exactly as long as before.
struct VolcTuningSettings: Codable, Sendable, Equatable {

    // MARK: Server request (sent in full_client_request)

    /// `enable_nonstream`: re-recognize each VAD segment with the non-streaming model.
    var enableNonstream: Bool = true
    /// Whether `end_window_size` is sent. When omitted the server falls back to
    /// semantic segmentation (or its 800 ms VAD default while nonstream is on).
    var sendEndWindowSize: Bool = true
    /// `end_window_size` (ms): silence needed before the server closes a segment.
    var endWindowSizeMs: Int = 3000
    /// Whether `force_to_speech_time` is sent.
    var sendForceToSpeechTime: Bool = true
    /// `force_to_speech_time` (ms): audio shorter than this is never closed.
    var forceToSpeechTimeMs: Int = 0
    /// Whether `vad_segment_duration` is sent. Ignored by the server whenever
    /// `end_window_size` is present.
    var sendVadSegmentDuration: Bool = false
    /// `vad_segment_duration` (ms): silence that splits semantic sentences.
    var vadSegmentDurationMs: Int = 3000
    /// `enable_accelerate_text`: return the first characters sooner.
    var enableAccelerateText: Bool = false
    /// `accelerate_score` (0–20), only meaningful with accelerate text on.
    var accelerateScore: Int = 0
    /// `enable_punc`.
    var enablePunc: Bool = true
    /// `enable_itn`: written-form numbers, dates and units.
    var enableITN: Bool = true
    /// `enable_ddc`: remove fillers and repetitions.
    var enableDDC: Bool = true
    /// `context_history_length`; 0 omits the field.
    var contextHistoryLength: Int = 20

    // MARK: Client handling

    /// Join utterances without a space when either side of the boundary is
    /// CJK (same rule as the Claude composer) instead of using `result.text`.
    var cjkAwareJoin: Bool = false
    /// How long stop waits for the server's final result before giving up.
    var finalWaitMs: Int = 2000
    /// When the final wait times out: `true` commits the current text at once,
    /// `false` keeps draining the stream for up to 5 s (shipped behavior).
    var commitOnFinalTimeout: Bool = false
    /// Short recordings (< 5 s) with no text yet wait this long for any text
    /// before being treated as silence.
    var shortRecordingFirstTextWaitMs: Int = 1000
    /// Size of each audio packet sent while recording.
    var audioChunkMs: Int = 200

    static let defaults = VolcTuningSettings()

    static let endWindowRange = 200...6000
    static let forceToSpeechRange = 0...5000
    static let vadSegmentRange = 200...6000
    static let accelerateScoreRange = 0...20
    static let contextHistoryRange = 0...50
    static let finalWaitRange = 0...5000
    static let shortRecordingWaitRange = 0...3000
    static let audioChunkOptions = [40, 60, 100, 160, 200]

    /// Final wait used by the short-recording fast path, which shipped at 1 s.
    var shortRecordingFinalWaitMs: Int { min(finalWaitMs, 1000) }

    var audioChunkByteSize: Int {
        let ms = Self.audioChunkOptions.contains(audioChunkMs) ? audioChunkMs : 200
        // 16 kHz mono Int16 = 32 bytes per millisecond.
        return ms * 32
    }

    var clamped: VolcTuningSettings {
        var copy = self
        copy.endWindowSizeMs = Self.clamp(endWindowSizeMs, Self.endWindowRange)
        copy.forceToSpeechTimeMs = Self.clamp(forceToSpeechTimeMs, Self.forceToSpeechRange)
        copy.vadSegmentDurationMs = Self.clamp(vadSegmentDurationMs, Self.vadSegmentRange)
        copy.accelerateScore = Self.clamp(accelerateScore, Self.accelerateScoreRange)
        copy.contextHistoryLength = Self.clamp(contextHistoryLength, Self.contextHistoryRange)
        copy.finalWaitMs = Self.clamp(finalWaitMs, Self.finalWaitRange)
        copy.shortRecordingFirstTextWaitMs = Self.clamp(shortRecordingFirstTextWaitMs, Self.shortRecordingWaitRange)
        if !Self.audioChunkOptions.contains(copy.audioChunkMs) { copy.audioChunkMs = 200 }
        return copy
    }

    /// Request fields that this panel owns, merged into `request` by
    /// `VolcProtocol.buildClientRequest`.
    func requestFields(enablePunc callerPunc: Bool) -> [String: Any] {
        var fields: [String: Any] = [
            "enable_punc": callerPunc && enablePunc,
            "enable_itn": enableITN,
            "enable_ddc": enableDDC,
            "enable_nonstream": enableNonstream,
        ]
        if sendEndWindowSize { fields["end_window_size"] = endWindowSizeMs }
        if sendForceToSpeechTime { fields["force_to_speech_time"] = forceToSpeechTimeMs }
        if sendVadSegmentDuration { fields["vad_segment_duration"] = vadSegmentDurationMs }
        if enableAccelerateText {
            fields["enable_accelerate_text"] = true
            fields["accelerate_score"] = accelerateScore
        }
        return fields
    }

    /// One-line summary for debug.log so each test recording records its knobs.
    var logSummary: String {
        let endWindow = sendEndWindowSize ? "\(endWindowSizeMs)" : "omit"
        let force = sendForceToSpeechTime ? "\(forceToSpeechTimeMs)" : "omit"
        let vad = sendVadSegmentDuration ? "\(vadSegmentDurationMs)" : "omit"
        let accel = enableAccelerateText ? "\(accelerateScore)" : "off"
        return "nonstream=\(enableNonstream) end_window=\(endWindow) force_to_speech=\(force) vad_segment=\(vad) "
            + "accel=\(accel) punc=\(enablePunc) itn=\(enableITN) ddc=\(enableDDC) ctx=\(contextHistoryLength) "
            + "cjkJoin=\(cjkAwareJoin) finalWait=\(finalWaitMs) commitOnTimeout=\(commitOnFinalTimeout) "
            + "shortWait=\(shortRecordingFirstTextWaitMs) chunk=\(audioChunkMs)"
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    init() {}

    init(from decoder: Decoder) throws {
        // Missing keys keep their defaults so new knobs never reset old ones.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VolcTuningSettings()
        enableNonstream = try c.decodeIfPresent(Bool.self, forKey: .enableNonstream) ?? d.enableNonstream
        sendEndWindowSize = try c.decodeIfPresent(Bool.self, forKey: .sendEndWindowSize) ?? d.sendEndWindowSize
        endWindowSizeMs = try c.decodeIfPresent(Int.self, forKey: .endWindowSizeMs) ?? d.endWindowSizeMs
        sendForceToSpeechTime = try c.decodeIfPresent(Bool.self, forKey: .sendForceToSpeechTime) ?? d.sendForceToSpeechTime
        forceToSpeechTimeMs = try c.decodeIfPresent(Int.self, forKey: .forceToSpeechTimeMs) ?? d.forceToSpeechTimeMs
        sendVadSegmentDuration = try c.decodeIfPresent(Bool.self, forKey: .sendVadSegmentDuration) ?? d.sendVadSegmentDuration
        vadSegmentDurationMs = try c.decodeIfPresent(Int.self, forKey: .vadSegmentDurationMs) ?? d.vadSegmentDurationMs
        enableAccelerateText = try c.decodeIfPresent(Bool.self, forKey: .enableAccelerateText) ?? d.enableAccelerateText
        accelerateScore = try c.decodeIfPresent(Int.self, forKey: .accelerateScore) ?? d.accelerateScore
        enablePunc = try c.decodeIfPresent(Bool.self, forKey: .enablePunc) ?? d.enablePunc
        enableITN = try c.decodeIfPresent(Bool.self, forKey: .enableITN) ?? d.enableITN
        enableDDC = try c.decodeIfPresent(Bool.self, forKey: .enableDDC) ?? d.enableDDC
        contextHistoryLength = try c.decodeIfPresent(Int.self, forKey: .contextHistoryLength) ?? d.contextHistoryLength
        cjkAwareJoin = try c.decodeIfPresent(Bool.self, forKey: .cjkAwareJoin) ?? d.cjkAwareJoin
        finalWaitMs = try c.decodeIfPresent(Int.self, forKey: .finalWaitMs) ?? d.finalWaitMs
        commitOnFinalTimeout = try c.decodeIfPresent(Bool.self, forKey: .commitOnFinalTimeout) ?? d.commitOnFinalTimeout
        shortRecordingFirstTextWaitMs = try c.decodeIfPresent(Int.self, forKey: .shortRecordingFirstTextWaitMs) ?? d.shortRecordingFirstTextWaitMs
        audioChunkMs = try c.decodeIfPresent(Int.self, forKey: .audioChunkMs) ?? d.audioChunkMs
    }
}

enum VolcTuningStorage {

    static let key = "tf_volcTuning"

    static func load() -> VolcTuningSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(VolcTuningSettings.self, from: data)
        else {
            return VolcTuningSettings()
        }
        return settings.clamped
    }

    static func save(_ settings: VolcTuningSettings) {
        guard let data = try? JSONEncoder().encode(settings.clamped) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Settings that apply to the session about to start: the saved knobs for
    /// Volcano, shipped defaults for every other provider.
    static func effective(for provider: ASRProvider) -> VolcTuningSettings {
        provider == .volcano ? load() : VolcTuningSettings()
    }
}

/// CJK-aware text join, mirroring the Claude composer's rule: insert a single
/// space only when neither side already has one, neither boundary character
/// is CJK (or full-width punctuation), and the next piece doesn't start with
/// sentence punctuation.
enum CJKAwareJoiner {

    static func join(_ pieces: [String]) -> String {
        pieces.reduce("") { join($0, $1) }
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let last = lhs.unicodeScalars.last, let first = rhs.unicodeScalars.first else {
            return lhs + rhs
        }
        if last.properties.isWhitespace || first.properties.isWhitespace { return lhs + rhs }
        if isCJK(last) || isCJK(first) { return lhs + rhs }
        if startsWithSentencePunctuation(rhs) { return lhs + rhs }
        return lhs + " " + rhs
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF,   // Thai, Lao
             0x1000...0x109F,   // Myanmar
             0x1780...0x17FF,   // Khmer
             0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF:   // Half/full-width forms
            return true
        default:
            return false
        }
    }

    private static func startsWithSentencePunctuation(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return ".,!?;:".contains(first)
    }
}
