import Foundation

/// Request parameters and stop-flow handling for one Volcano streaming session.
///
/// The defaults are the "accurate" preset: the endpointing that shipped before
/// presets existed, plus CJK-aware sentence joining.
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
    /// CJK (same rule as the Claude composer) instead of using `result.text`,
    /// which separates every pair of sentences with an ASCII space.
    var cjkAwareJoin: Bool = true
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

    /// Waits for about 3 s of silence before closing a sentence, so a thinking
    /// pause stays inside one sentence and is punctuated as a whole.
    static let accurate = VolcTuningSettings()

    /// Lets the server close sentences after its default 0.8 s of silence and
    /// commits the current text if the final result is slow, for a faster
    /// release at the cost of extra full stops at pauses.
    static let fast: VolcTuningSettings = {
        var settings = VolcTuningSettings()
        settings.sendEndWindowSize = false
        settings.endWindowSizeMs = 800
        settings.sendForceToSpeechTime = false
        settings.forceToSpeechTimeMs = 1000
        settings.sendVadSegmentDuration = true
        settings.vadSegmentDurationMs = 6000
        settings.contextHistoryLength = 50
        settings.finalWaitMs = 3000
        settings.commitOnFinalTimeout = true
        return settings
    }()

    /// The server's own silence threshold when `end_window_size` is omitted
    /// while two-pass recognition is on.
    static let serverDefaultEndWindowMs = 800

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

/// The preset a user picks for Volcano recognition.
enum VolcRecognitionPreset: String, Codable, CaseIterable, Sendable {
    case accurate
    case fast
    case custom

    var displayName: String {
        switch self {
        case .accurate: return L("准确", "Accurate")
        case .fast: return L("快速", "Fast")
        case .custom: return L("自定义", "Custom")
        }
    }
}

/// Saved choice plus the user's own parameters, kept even while a fixed
/// preset is selected so switching back to custom restores them.
/// Fast is the default: release-to-text is quicker, and the extra full stops
/// it leaves at pauses are minor next to the wait it saves.
struct VolcRecognitionProfile: Codable, Sendable, Equatable {
    var preset: VolcRecognitionPreset = .fast
    var custom: VolcTuningSettings?

    var effectiveSettings: VolcTuningSettings {
        switch preset {
        case .accurate: return .accurate
        case .fast: return .fast
        case .custom: return (custom ?? .fast).clamped
        }
    }
}

enum VolcRecognitionProfileStore {

    static let key = "tf_volcRecognitionProfile"
    /// Written by the experimental tuning panel used during local testing.
    static let legacyTuningKey = "tf_volcTuning"

    static func load(userDefaults: UserDefaults = .standard) -> VolcRecognitionProfile {
        if let data = userDefaults.data(forKey: key),
           let profile = try? JSONDecoder().decode(VolcRecognitionProfile.self, from: data) {
            return profile
        }
        if let migrated = migrateLegacyTuning(userDefaults: userDefaults) {
            return migrated
        }
        return VolcRecognitionProfile()
    }

    static func save(_ profile: VolcRecognitionProfile, userDefaults: UserDefaults = .standard) {
        var profile = profile
        profile.custom = profile.custom?.clamped
        guard let data = try? JSONEncoder().encode(profile) else { return }
        userDefaults.set(data, forKey: key)
    }

    /// One-time conversion of the experimental panel's saved parameters:
    /// values matching a preset select it, anything else becomes custom.
    private static func migrateLegacyTuning(userDefaults: UserDefaults) -> VolcRecognitionProfile? {
        guard let data = userDefaults.data(forKey: legacyTuningKey),
              let legacy = try? JSONDecoder().decode(VolcTuningSettings.self, from: data)
        else { return nil }
        let settings = legacy.clamped
        let profile: VolcRecognitionProfile
        if settings == .fast {
            profile = VolcRecognitionProfile(preset: .fast, custom: nil)
        } else if settings == .accurate {
            profile = VolcRecognitionProfile(preset: .accurate, custom: nil)
        } else {
            profile = VolcRecognitionProfile(preset: .custom, custom: settings)
        }
        save(profile, userDefaults: userDefaults)
        userDefaults.removeObject(forKey: legacyTuningKey)
        return profile
    }
}

enum VolcTuningStorage {

    /// Parameters for the Volcano session about to start.
    static func load() -> VolcTuningSettings {
        VolcRecognitionProfileStore.load().effectiveSettings
    }

    /// Settings that apply to the session about to start: the selected preset
    /// for Volcano, the accurate defaults for every other provider.
    static func effective(for provider: ASRProvider) -> VolcTuningSettings {
        provider == .volcano ? load() : .accurate
    }
}

/// CJK-aware text join, mirroring the Claude composer's rule: pieces meet with
/// a single space only when neither boundary character is CJK (or full-width
/// punctuation) and the next piece doesn't start with sentence punctuation.
/// Whitespace the server leaves at a boundary is dropped next to CJK text, so
/// "PR。" + " 然后" becomes "PR。然后".
enum CJKAwareJoiner {

    static func join(_ pieces: [String]) -> String {
        pieces.reduce("") { join($0, $1) }
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        let left = trimmingTrailingWhitespace(lhs)
        let right = trimmingLeadingWhitespace(rhs)
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            // One side was only whitespace; keep the other side as it was.
            return left.isEmpty ? lhs + right : left + rhs
        }
        if isCJK(last) || isCJK(first) { return left + right }
        if startsWithSentencePunctuation(right) { return left + right }
        return left + " " + right
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    private static func trimmingLeadingWhitespace(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        return String(scalars)
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
