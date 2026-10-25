import Foundation

/// One mode the user keeps in the app. Built-in modes carry their prompt in
/// code (`ModePrompts`); custom ones carry the user's own prompt.
struct ModeDefinition: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case quick
        case formalWriting
        /// The Mac's Translation mode. The raw value predates choosing a
        /// target language; it stays so stored libraries and history match.
        case translation = "translateEnglish"
        case agentMode
        case custom
    }

    /// Stable ID, persisted in history and sent over IPC. Built-in modes use
    /// their kind's raw value.
    var id: String
    var kind: Kind
    /// The user's own name. nil renders the built-in name in the current
    /// language; custom modes always have one.
    var name: String?
    /// Custom modes only. `{text}` is replaced with the transcript; without it
    /// the prompt is sent as the system message and the transcript as the user one.
    var prompt: String = ""
    var onKeyboard: Bool
    /// Translation only: a Mac `TranslationLanguage` code. nil means English.
    var targetLanguage: String?

    var translationTarget: TranslationLanguage {
        targetLanguage.flatMap(TranslationLanguage.init(rawValue:)) ?? .english
    }

    var isBuiltIn: Bool { kind != .custom }

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return Self.builtInName(kind, target: translationTarget)
    }

    /// Translation shows its target, short enough for a keyboard chip.
    static func builtInName(_ kind: Kind, target: TranslationLanguage) -> String {
        guard kind == .translation else { return builtInName(kind) }
        return builtInName(kind) + " · " + target.shortTag
    }

    static func builtInName(_ kind: Kind) -> String {
        switch kind {
        case .quick: return L("快速", "Quick")
        case .formalWriting: return L("语音润色", "Voice Polish")
        case .translation: return L("翻译", "Translate")
        case .agentMode: return L("代办", "Handle It")
        case .custom: return L("自定义模式", "Custom Mode")
        }
    }

    static func builtIn(_ kind: Kind) -> ModeDefinition {
        ModeDefinition(id: kind.rawValue, kind: kind, name: nil, onKeyboard: true)
    }
}

/// The user's modes in display order, shared with the keyboard through the
/// App Group. The app edits it; the keyboard only reads it.
enum ModeLibrary {
    /// The keyboard's switcher fits this many chips.
    static let keyboardLimit = 4

    private static let key = "modes.v1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (data: Data, modes: [ModeDefinition])?

    /// The Mac modes that make sense on a phone keyboard. Mac Action, Ask
    /// Anything and Intelli Sense need the Mac; Prompt Optimizer stays there too.
    static let defaults: [ModeDefinition] = [
        .builtIn(.formalWriting), .builtIn(.quick), .builtIn(.translation), .builtIn(.agentMode),
    ]

    static var all: [ModeDefinition] {
        get {
            guard let data = SharedContainer.defaults?.data(forKey: key) else { return defaults }
            lock.lock()
            defer { lock.unlock() }
            if let cache, cache.data == data { return cache.modes }
            guard let decoded = try? JSONDecoder().decode([StoredMode].self, from: data) else { return defaults }
            let modes = repaired(decoded.compactMap(\.mode))
            cache = (data, modes)
            return modes
        }
        set {
            guard let data = try? JSONEncoder().encode(repaired(newValue)) else { return }
            SharedContainer.defaults?.set(data, forKey: key)
        }
    }

    /// Shown on the keyboard, in library order.
    static var keyboardModes: [ModeDefinition] {
        Array(all.filter(\.onKeyboard).prefix(keyboardLimit))
    }

    static func definition(for id: String) -> ModeDefinition? {
        all.first { $0.id == id }
    }

    /// Built-in modes can't be deleted, so put back any that went missing,
    /// drop duplicate IDs, and keep at least one mode on the keyboard.
    private static func repaired(_ modes: [ModeDefinition]) -> [ModeDefinition] {
        var seen = Set<String>()
        var result = modes.filter { seen.insert($0.id).inserted }
        for builtIn in defaults where !seen.contains(builtIn.id) {
            var restored = builtIn
            restored.onKeyboard = false
            result.append(restored)
        }
        if !result.contains(where: \.onKeyboard), let index = result.firstIndex(where: { $0.kind == .quick }) {
            result[index].onKeyboard = true
        }
        return result
    }
}

/// One library entry as stored. Kinds this build doesn't know are dropped
/// instead of failing the whole library; Intelli Sense, which the iPhone no
/// longer has, hands its place to Voice Polish.
private struct StoredMode: Decodable {
    let mode: ModeDefinition?

    private enum Keys: String, CodingKey {
        case kind, onKeyboard
    }

    init(from decoder: Decoder) throws {
        if let mode = try? ModeDefinition(from: decoder) {
            self.mode = mode
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        guard try container.decodeIfPresent(String.self, forKey: .kind) == DictationMode.legacyIntelliSenseID else {
            mode = nil
            return
        }
        var polish = ModeDefinition.builtIn(.formalWriting)
        polish.onKeyboard = try container.decodeIfPresent(Bool.self, forKey: .onKeyboard) ?? true
        mode = polish
    }
}

/// A mode as the keyboard, IPC and history refer to it: just its stable ID.
/// Encodes as the bare string, so history and IPC written before custom
/// modes existed still decode.
struct DictationMode: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    init(_ definition: ModeDefinition) {
        rawValue = definition.id
    }

    private init(id: String) {
        rawValue = id
    }

    static let quick = DictationMode(id: ModeDefinition.Kind.quick.rawValue)
    static let formalWriting = DictationMode(id: ModeDefinition.Kind.formalWriting.rawValue)
    static let translation = DictationMode(id: ModeDefinition.Kind.translation.rawValue)
    static let agentMode = DictationMode(id: ModeDefinition.Kind.agentMode.rawValue)

    /// History written before the iPhone dropped Intelli Sense still carries this ID.
    static let legacyIntelliSenseID = "intelliSense"

    var id: String { rawValue }

    var definition: ModeDefinition? { ModeLibrary.definition(for: rawValue) }

    var kind: ModeDefinition.Kind {
        definition?.kind ?? ModeDefinition.Kind(rawValue: rawValue) ?? .custom
    }

    var title: String {
        if let definition { return definition.displayName }
        if let kind = ModeDefinition.Kind(rawValue: rawValue), kind != .custom {
            return ModeDefinition.builtInName(kind)
        }
        if rawValue == Self.legacyIntelliSenseID { return L("智能感知", "Intelli Sense") }
        return L("已删除的模式", "Deleted Mode")
    }

    var processingLabel: String {
        switch kind {
        case .quick: return L("识别中", "Recognizing")
        case .formalWriting: return L("润色中", "Polishing")
        case .translation: return L("翻译中", "Translating")
        case .agentMode: return L("处理中", "Handling")
        case .custom: return L("处理中", "Processing")
        }
    }

    var usesLLM: Bool { kind != .quick }

    /// Chips on the keyboard, as chosen in Settings › Modes.
    static var keyboardOrder: [DictationMode] {
        ModeLibrary.keyboardModes.map(DictationMode.init)
    }

    /// Every mode in the library, for filters and pickers in the app.
    static var allModes: [DictationMode] {
        ModeLibrary.all.map(DictationMode.init)
    }
}

extension TranslationLanguage {
    /// Compact label for keyboard chips: EN, JA, 简中 …
    var shortTag: String {
        switch self {
        case .simplifiedChinese: return L("简中", "ZH")
        case .traditionalChinese: return L("繁中", "ZH-TW")
        case .brazilianPortuguese: return "PT"
        default: return rawValue.uppercased()
        }
    }
}
