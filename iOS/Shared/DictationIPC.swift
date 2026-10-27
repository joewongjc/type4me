import Foundation

// The keyboard cannot record audio, so every dictation runs in the app while
// it sits in the background. The two processes talk through files in the App
// Group container, with Darwin notifications as the doorbell:
//
//   keyboard ── command file + "command" ──▶ app
//   keyboard ◀──── state.json + "state" ──── app
//
// A Darwin notification carries no payload and is only delivered to a process
// that is running, which is exactly the liveness test the keyboard needs: if a
// ping gets no answer, the app is not in the background and the keyboard has
// to open it.

enum DarwinName {
    static let command = "com.type4me.ios.command"
    static let state = "com.type4me.ios.state"
    static let keyboardAppeared = "com.type4me.ios.keyboardAppeared"
}

struct KeyboardCommand: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Begin recording for `requestID`.
        case start
        /// Stop recording and deliver the text.
        case stop
        /// Drop the recording without output.
        case cancel
        /// Are you there? The app answers with a state write carrying `pongFor`.
        case ping
        /// The keyboard reports what it did with the text for `requestID`.
        case delivered
        /// Add `hotword` to the vocabulary; answered with `rememberedHotword`.
        case rememberHotword
    }

    enum Delivery: String, Codable, Sendable {
        case inserted
        /// The text field changed while processing, so the text went to the clipboard.
        case copied
    }

    var id = UUID()
    var kind: Kind
    var requestID: UUID?
    var mode: DictationMode?
    var delivery: Delivery?
    /// Intelli Sense only, on start and again on stop: what the keyboard
    /// can see of the text field.
    var field: FieldContext?
    /// On start: correct this selection instead of dictating.
    var correction: CorrectionRequest?
    var hotword: String?
    var sentAt = Date()
}

/// The part of the text field a keyboard can see. iOS doesn't tell a
/// keyboard which app it's in, so the field's own traits stand in for it.
struct FieldContext: Codable, Equatable, Sendable {
    /// Up to `beforeLimit` characters before the cursor and `afterLimit`
    /// after it, the same window the Mac reads; empty when reading context
    /// is off or the field looks sensitive.
    var before = ""
    var after = ""
    /// `UIKeyboardType`, `UIReturnKeyType` and `UITextContentType` raw values.
    var keyboardType = 0
    var returnKeyType = 0
    var textContentType: String?
    /// Passwords, one-time codes, card numbers and the like.
    var isSensitive = false

    static let beforeLimit = 300
    static let afterLimit = 100
}

struct DictationState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case idle
        case recording
        case processing
        case done
        case failed
    }

    /// Changes on every app launch; lets the keyboard notice a restart.
    var instanceID: UUID
    var sessionActive: Bool
    var sessionExpiresAt: Date?
    var phase: Phase = .idle
    var requestID: UUID?
    var mode: DictationMode?
    var liveText = ""
    var finalText: String?
    /// A finished correction, in place of `finalText`.
    var correction: CorrectionOutcome?
    var errorMessage: String?
    /// The app could not open the microphone from the background; the keyboard
    /// should bring the app forward once so it can.
    var needsForeground = false
    /// 0…1 input level for the waveform while recording.
    var level: Float = 0
    var pongFor: UUID?
    var rememberedHotword: String?
    var updatedAt = Date()
}

enum DictationChannel {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    // MARK: Keyboard side

    @discardableResult
    static func send(_ command: KeyboardCommand, notify: Bool = true) -> Bool {
        guard let dir = SharedContainer.commandsDirectory,
              let data = try? encoder.encode(command)
        else { return false }
        // Millisecond prefix keeps files in send order when the app drains them.
        let stamp = String(format: "%013.0f", command.sentAt.timeIntervalSince1970 * 1000)
        let file = dir.appendingPathComponent("\(stamp)-\(command.id.uuidString).json")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return false
        }
        if notify { DarwinNotifier.post(DarwinName.command) }
        return true
    }

    static func readState() -> DictationState? {
        guard let file = SharedContainer.stateFile,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return try? decoder.decode(DictationState.self, from: data)
    }

    // MARK: App side

    /// Reads and removes every pending command, oldest first.
    static func drainCommands() -> [KeyboardCommand] {
        guard let dir = SharedContainer.commandsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
              )
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                defer { try? FileManager.default.removeItem(at: file) }
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? decoder.decode(KeyboardCommand.self, from: data)
            }
    }

    static func write(_ state: DictationState) {
        guard let file = SharedContainer.stateFile,
              let data = try? encoder.encode(state)
        else { return }
        try? data.write(to: file, options: .atomic)
        DarwinNotifier.post(DarwinName.state)
    }
}

/// Thin wrapper over the Darwin notify center with closure observers.
final class DarwinNotifier {
    static let shared = DarwinNotifier()

    private var handlers: [String: [() -> Void]] = [:]
    private let lock = NSLock()

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Handlers run on the main queue.
    func observe(_ name: String, handler: @escaping () -> Void) {
        lock.lock()
        let isFirst = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard isFirst else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let notifier = Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue()
                notifier.fire(name.rawValue as String)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    func removeAll() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func fire(_ name: String) {
        lock.lock()
        let current = handlers[name] ?? []
        lock.unlock()
        DispatchQueue.main.async {
            current.forEach { $0() }
        }
    }
}
