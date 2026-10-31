import AVFoundation

/// Tells "a call or another app holds the microphone" apart from other
/// reasons the microphone would not open, so the keyboard can say so in plain
/// words.
///
/// It only reads a failure that already happened. Apps that listen in the
/// background with a mixable session (Grab, for example) don't stop us from
/// recording, so nothing here warns before we try.
///
/// CallKit's call observer would name calls specifically, but CallKit is off
/// limits for apps on the China App Store, so calls share one message with
/// other apps.
enum MicrophoneBusy: Equatable {
    /// A call, or another app recording or holding a higher-priority session.
    case otherApp
    /// Siri is listening.
    case siri

    var message: String {
        switch self {
        case .otherApp:
            return L("麦克风正被通话或其他 App 占用，结束后再试", "A call or another app is using the microphone. Try again when it's done.")
        case .siri:
            return L("Siri 正在使用麦克风，请稍后再试", "Siri is using the microphone. Try again in a moment.")
        }
    }

    /// The same thing for when a recording was cut off part way.
    var interruptedMessage: String {
        switch self {
        case .otherApp:
            return L("麦克风被通话或其他 App 占用，录音已停止", "A call or another app took the microphone, so recording stopped.")
        case .siri:
            return L("Siri 开始使用麦克风，录音已停止", "Siri took the microphone, so recording stopped.")
        }
    }

    /// The reason something else is in the way, or nil when the failure looks
    /// like something else (permissions, background eligibility, no input).
    ///
    /// '!rec' is also what iOS answers when the app may not record from the
    /// background, so it only counts as busy while the app is in front.
    static func reason(for errors: [Error], inForeground: Bool) -> MicrophoneBusy? {
        let codes = Set(errors.flatMap(codes(in:)))
        if codes.contains(AVAudioSession.ErrorCode.siriIsRecording.rawValue) { return .siri }
        if !codes.isDisjoint(with: busyCodes) { return .otherApp }
        if inForeground, codes.contains(AVAudioSession.ErrorCode.cannotStartRecording.rawValue) { return .otherApp }
        return nil
    }

    /// Why an interruption cut a recording off, or nil when it wasn't a call
    /// or another app (the app was suspended, the built-in mic was muted, the
    /// route went away).
    static func reason(forInterruption info: [AnyHashable: Any]?) -> MicrophoneBusy? {
        if let raw = info?[AVAudioSessionInterruptionReasonKey] as? UInt,
           let kind = AVAudioSession.InterruptionReason(rawValue: raw),
           kind != .default {
            return nil
        }
        return .otherApp
    }

    /// Core Audio codes that mean another client holds the session or has a
    /// higher priority than ours.
    private static let busyCodes: Set<Int> = [
        AVAudioSession.ErrorCode.insufficientPriority.rawValue, // '!pri'
        AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue, // '!int'
        AVAudioSession.ErrorCode.isBusy.rawValue, // '!act'
    ]

    /// The error's code and those of the errors it wraps.
    private static func codes(in error: Error) -> [Int] {
        var result: [Int] = []
        var next: NSError? = error as NSError
        var depth = 0
        while let current = next, depth < 4 {
            result.append(current.code)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return result
    }
}
