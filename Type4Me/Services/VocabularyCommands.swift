import Foundation

enum VocabularySection: String, Sendable, Hashable {
    case hotwords
    case snippets
}

enum VocabularyDraftFocus: Sendable {
    case hotword
    case snippetTrigger
    case snippetReplacement
}

struct VocabularyNavigationRequest: Equatable, Sendable {
    let id: UUID
    let section: VocabularySection
    let word: String?
    let trigger: String?
    let replacement: String?

    init(
        id: UUID = UUID(),
        section: VocabularySection,
        word: String? = nil,
        trigger: String? = nil,
        replacement: String? = nil
    ) {
        self.id = id
        self.section = section
        self.word = word
        self.trigger = trigger
        self.replacement = replacement
    }

    var focus: VocabularyDraftFocus? {
        switch section {
        case .hotwords:
            return .hotword
        case .snippets:
            if trigger != nil && replacement == nil { return .snippetReplacement }
            if trigger == nil && replacement != nil { return .snippetTrigger }
            if trigger != nil || replacement != nil { return .snippetReplacement }
            return nil
        }
    }
}

@MainActor
final class VocabularyNavigationCenter {
    static let shared = VocabularyNavigationCenter()

    private(set) var pendingRequest: VocabularyNavigationRequest?
    private(set) var hasPendingSettingsNavigation = false

    private init() {}

    func submit(_ request: VocabularyNavigationRequest) {
        pendingRequest = request
        hasPendingSettingsNavigation = true
        NotificationCenter.default.post(name: .navigateToVocabulary, object: request)
    }

    func consume(_ request: VocabularyNavigationRequest) {
        guard pendingRequest?.id == request.id else { return }
        pendingRequest = nil
    }

    func consumeSettingsNavigation() {
        hasPendingSettingsNavigation = false
    }
}

struct VocabularyURLCommand: Equatable, Sendable {
    let section: VocabularySection
    let word: String?
    let trigger: String?
    let replacement: String?
    let silent: Bool

    var navigationRequest: VocabularyNavigationRequest {
        VocabularyNavigationRequest(
            section: section,
            word: word,
            trigger: trigger,
            replacement: replacement
        )
    }
}

enum VocabularyURLCommandError: Error, Equatable {
    case unsupportedScheme
    case urlTooLong
    case invalidPath
    case unsupportedParameter
    case duplicateParameter
    case invalidSilentValue
    case invalidValue
    case missingRequiredParameter
}

enum VocabularyURLCommandParser {
    static let maximumURLBytes = 8 * 1024
    static let maximumTermLength = 256
    static let maximumReplacementLength = 4_096

    static func parse(
        _ url: URL,
        allowedSchemes: Set<String>
    ) -> Result<VocabularyURLCommand, VocabularyURLCommandError> {
        guard url.absoluteString.utf8.count <= maximumURLBytes else {
            return .failure(.urlTooLong)
        }
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.map({ $0.lowercased() }).contains(scheme) else {
            return .failure(.unsupportedScheme)
        }
        guard url.host?.lowercased() == "vocabulary" else {
            return .failure(.invalidPath)
        }

        let pathParts = url.path.split(separator: "/").map(String.init)
        guard pathParts.count == 1,
              let section = VocabularySection(rawValue: pathParts[0].lowercased()) else {
            return .failure(.invalidPath)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidValue)
        }

        let allowedNames: Set<String> = section == .hotwords
            ? ["word", "silent"]
            : ["trigger", "replacement", "silent"]
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard allowedNames.contains(name) else {
                return .failure(.unsupportedParameter)
            }
            guard values[name] == nil else {
                return .failure(.duplicateParameter)
            }
            values[name] = item.value ?? ""
        }

        let silent: Bool
        switch values["silent"]?.lowercased() {
        case nil, "false", "0": silent = false
        case "true", "1": silent = true
        default: return .failure(.invalidSilentValue)
        }

        func validated(_ name: String, maximumLength: Int) -> Result<String?, VocabularyURLCommandError> {
            guard let raw = values[name] else { return .success(nil) }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value.count <= maximumLength,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return .failure(.invalidValue)
            }
            return .success(value)
        }

        let word: String?
        let trigger: String?
        let replacement: String?
        switch validated("word", maximumLength: maximumTermLength) {
        case .success(let value): word = value
        case .failure(let error): return .failure(error)
        }
        switch validated("trigger", maximumLength: maximumTermLength) {
        case .success(let value): trigger = value
        case .failure(let error): return .failure(error)
        }
        switch validated("replacement", maximumLength: maximumReplacementLength) {
        case .success(let value): replacement = value
        case .failure(let error): return .failure(error)
        }

        if silent {
            switch section {
            case .hotwords where word == nil:
                return .failure(.missingRequiredParameter)
            case .snippets where trigger == nil || replacement == nil:
                return .failure(.missingRequiredParameter)
            default:
                break
            }
        }

        return .success(VocabularyURLCommand(
            section: section,
            word: word,
            trigger: trigger,
            replacement: replacement,
            silent: silent
        ))
    }
}

enum VocabularyCommandResult: Equatable, Sendable {
    case added
    case alreadyExists
    case conflict
    case invalidInput
    case saveFailed
}

struct VocabularyCommandService {
    typealias Snippet = (trigger: String, value: String)

    private let loadHotwords: () -> [String]
    private let saveHotwords: ([String]) throws -> Void
    private let loadSnippets: () -> [Snippet]
    private let saveSnippets: ([Snippet]) throws -> Void

    static let live = VocabularyCommandService(
        loadHotwords: HotwordStorage.load,
        saveHotwords: HotwordStorage.saveOrThrow,
        loadSnippets: SnippetStorage.load,
        saveSnippets: SnippetStorage.saveOrThrow
    )

    init(
        loadHotwords: @escaping () -> [String],
        saveHotwords: @escaping ([String]) throws -> Void,
        loadSnippets: @escaping () -> [Snippet],
        saveSnippets: @escaping ([Snippet]) throws -> Void
    ) {
        self.loadHotwords = loadHotwords
        self.saveHotwords = saveHotwords
        self.loadSnippets = loadSnippets
        self.saveSnippets = saveSnippets
    }

    func addHotword(_ rawWord: String) -> VocabularyCommandResult {
        guard let word = Self.validated(rawWord, maximumLength: VocabularyURLCommandParser.maximumTermLength) else {
            return .invalidInput
        }
        var words = loadHotwords()
        if words.contains(where: { $0.localizedCaseInsensitiveCompare(word) == .orderedSame }) {
            return .alreadyExists
        }
        words.append(word)
        do {
            try saveHotwords(words)
            return .added
        } catch {
            return .saveFailed
        }
    }

    func addSnippet(trigger rawTrigger: String, replacement rawReplacement: String) -> VocabularyCommandResult {
        guard let trigger = Self.validated(
            rawTrigger,
            maximumLength: VocabularyURLCommandParser.maximumTermLength
        ), let replacement = Self.validated(
            rawReplacement,
            maximumLength: VocabularyURLCommandParser.maximumReplacementLength
        ) else {
            return .invalidInput
        }

        var snippets = loadSnippets()
        if let existing = snippets.first(where: {
            $0.trigger.localizedCaseInsensitiveCompare(trigger) == .orderedSame
        }) {
            return existing.value == replacement ? .alreadyExists : .conflict
        }
        snippets.append((trigger: trigger, value: replacement))
        do {
            try saveSnippets(snippets)
            return .added
        } catch {
            return .saveFailed
        }
    }

    static func validated(_ raw: String, maximumLength: Int) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumLength,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }
}
