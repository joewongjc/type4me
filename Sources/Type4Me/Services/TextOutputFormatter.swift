import Foundation

enum CJKSpacingMode: String, CaseIterable {
    static let storageKey = "tf_cjkSpacingMode"
    static let legacyStorageKey = "tf_preserveCJKLatinSpacing"
    static let defaultValue = Self.pangu.rawValue

    case pangu
    case off
    case remove

    static func current(userDefaults: UserDefaults = .standard) -> Self {
        if let raw = userDefaults.string(forKey: storageKey),
           let mode = Self(rawValue: raw) {
            return mode
        }
        if let legacy = userDefaults.object(forKey: legacyStorageKey) as? Bool {
            return legacy ? .pangu : .remove
        }
        return .pangu
    }

    static func migrateIfNeeded(userDefaults: UserDefaults = .standard) {
        if let raw = userDefaults.string(forKey: storageKey), Self(rawValue: raw) != nil {
            return
        }
        userDefaults.set(current(userDefaults: userDefaults).rawValue, forKey: storageKey)
    }
}

enum CornerQuotePreference {
    static let storageKey = "tf_useCornerQuotes"
    static let defaultValue = false
}

enum TrailingPunctuationMode: String {
    case off
    case period
    case all
}

enum ModePunctuationMode: String, Codable, CaseIterable, Sendable {
    case inherit
    case preserve
    case stripTrailing
    case questionsAndExclamationsOnly
    case removeAll

    fileprivate var override: OutputPunctuationMode? {
        switch self {
        case .inherit: nil
        case .preserve: .preserve
        case .stripTrailing: .stripTrailing
        case .questionsAndExclamationsOnly: .questionsAndExclamationsOnly
        case .removeAll: .removeAll
        }
    }
}

enum OutputPunctuationMode: Equatable {
    case preserve
    case stripPeriods
    case stripTrailing
    case questionsAndExclamationsOnly
    case removeAll
}

struct TextOutputFormattingOptions: Equatable {
    var cjkSpacingMode: CJKSpacingMode
    var usesCornerQuotes: Bool
    var punctuationMode: OutputPunctuationMode

    init(
        cjkSpacingMode: CJKSpacingMode,
        usesCornerQuotes: Bool,
        punctuationMode: OutputPunctuationMode
    ) {
        self.cjkSpacingMode = cjkSpacingMode
        self.usesCornerQuotes = usesCornerQuotes
        self.punctuationMode = punctuationMode
    }

    /// Compatibility initializer for callers that still express the global
    /// trailing-punctuation preference directly.
    init(
        cjkSpacingMode: CJKSpacingMode,
        usesCornerQuotes: Bool,
        trailingPunctuationMode: TrailingPunctuationMode
    ) {
        self.init(
            cjkSpacingMode: cjkSpacingMode,
            usesCornerQuotes: usesCornerQuotes,
            punctuationMode: Self.outputMode(for: trailingPunctuationMode)
        )
    }

    static func current(
        userDefaults: UserDefaults = .standard,
        modePunctuation: ModePunctuationMode = .inherit
    ) -> Self {
        let usesCornerQuotes = userDefaults.object(forKey: CornerQuotePreference.storageKey) as? Bool
            ?? CornerQuotePreference.defaultValue
        let trailing = userDefaults.string(forKey: "tf_stripTrailingPunctuation")
            .flatMap(TrailingPunctuationMode.init(rawValue:)) ?? .off
        return Self(
            cjkSpacingMode: CJKSpacingMode.current(userDefaults: userDefaults),
            usesCornerQuotes: usesCornerQuotes,
            punctuationMode: modePunctuation.override ?? outputMode(for: trailing)
        )
    }

    private static func outputMode(for mode: TrailingPunctuationMode) -> OutputPunctuationMode {
        switch mode {
        case .off: .preserve
        case .period: .stripPeriods
        case .all: .stripTrailing
        }
    }
}

enum TextOutputFormatter {
    static func format(
        _ text: String,
        options: TextOutputFormattingOptions
    ) -> String {
        var result = options.usesCornerQuotes ? replacingCurlyQuotes(in: text) : text
        switch options.cjkSpacingMode {
        case .pangu:
            result = PanguSpacing.spacingText(result)
        case .off:
            break
        case .remove:
            result = removingSpacesAdjacentToHan(in: result)
        }
        result = applyingPunctuationMode(options.punctuationMode, to: result)

        // Removing punctuation can create a new CJK/Latin boundary that did not
        // exist during the spacing pass. Stabilize that boundary inside the
        // punctuation stage so formatting remains idempotent.
        if options.cjkSpacingMode == .pangu {
            switch options.punctuationMode {
            case .questionsAndExclamationsOnly, .removeAll:
                result = PanguSpacing.spacingText(result)
            case .preserve, .stripPeriods, .stripTrailing:
                break
            }
        }
        return result
    }

    static func format(_ text: String, userDefaults: UserDefaults = .standard) -> String {
        format(text, options: .current(userDefaults: userDefaults))
    }

    private static func replacingCurlyQuotes(in text: String) -> String {
        // Protect English apostrophes (e.g., I’m, there’s, don’t, users’, ’90s)
        // so that typographic apostrophes (U+2019) are not mistaken for closing single quotes (』).
        let apostrophePlaceholder = "\u{E020}"

        // 1. In-word contractions & possessives: I'm, there's, don't, Apple's
        var protectedText = RegexSupport.replace(
            #"(?<=[A-Za-z0-9])’(?=[A-Za-z0-9])"#,
            in: text,
            with: apostrophePlaceholder
        )

        // 2. Trailing plural possessives: users' guide, James' book (not preceded by opening single quote)
        protectedText = RegexSupport.replace(
            #"(?<!‘)(?<=[A-Za-z0-9])’(?=[\s\.,!?;:\)\]\}，。！？；：）】]|$)"#,
            in: protectedText,
            with: apostrophePlaceholder
        )

        // 3. Leading decade/word omissions: ’90s, ’em, ’cause, rock ’n’ roll
        protectedText = RegexSupport.replace(
            #"(?<=^|[\s\(\[\{<，。！？；：（【])’(?=[0-9]{2}s?\b|[A-Za-z]+\b(?!\s*’))"#,
            in: protectedText,
            with: apostrophePlaceholder
        )

        // Replace curly quotes with corner quotes
        let converted = protectedText
            .replacingOccurrences(of: "“", with: "「")
            .replacingOccurrences(of: "”", with: "」")
            .replacingOccurrences(of: "‘", with: "『")
            .replacingOccurrences(of: "’", with: "』")

        return converted.replacingOccurrences(of: apostrophePlaceholder, with: "’")
    }

    /// Preserves the old "remove CJK/Latin spacing" behavior for compatibility.
    private static func removingSpacesAdjacentToHan(in text: String) -> String {
        let han = "[\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF]"
        var result = RegexSupport.replace(#"(?<="# + han + #") +(?=\S)"#, in: text, with: "")
        result = RegexSupport.replace(#"(?<=\S) +(?="# + han + #")"#, in: result, with: "")
        return result
    }

    private static let cjkPunctuation = CharacterSet(charactersIn:
        "\u{3002}\u{FF0C}\u{FF01}\u{FF1F}\u{FF1B}\u{FF1A}\u{3001}\u{2026}\u{2014}\u{FF5E}\u{00B7}" +
        "\u{300C}\u{300D}\u{300E}\u{300F}\u{3010}\u{3011}\u{FF08}\u{FF09}\u{300A}\u{300B}" +
        "\u{201C}\u{201D}\u{2018}\u{2019}"
    )
    private static let punctuation = CharacterSet.punctuationCharacters.union(cjkPunctuation)
    private static let questionAndExclamationMarks = CharacterSet(charactersIn: "!?！？")

    private static func applyingPunctuationMode(
        _ mode: OutputPunctuationMode,
        to text: String
    ) -> String {
        guard !text.isEmpty else { return text }

        switch mode {
        case .preserve:
            return text
        case .stripPeriods:
            var result = text
            while result.hasSuffix("。") || result.hasSuffix(".") {
                result.removeLast()
            }
            return result
        case .stripTrailing:
            var result = text
            while let last = result.unicodeScalars.last, punctuation.contains(last) {
                result.unicodeScalars.removeLast()
            }
            return result
        case .questionsAndExclamationsOnly:
            return removingPunctuation(from: text, preserving: questionAndExclamationMarks)
        case .removeAll:
            return removingPunctuation(from: text, preserving: nil)
        }
    }

    private static func removingPunctuation(
        from text: String,
        preserving preserved: CharacterSet?
    ) -> String {
        String(text.unicodeScalars.filter { scalar in
            !punctuation.contains(scalar) || preserved?.contains(scalar) == true
        })
    }
}

private enum RegexSupport {
    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regular expression: \(pattern): \(error)")
        }
    }

    static func replace(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        replace(regex(pattern, options: options), in: text, with: template)
    }

    static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    static func replaceMatches(
        _ regex: NSRegularExpression,
        in text: String,
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let source = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            if let replacement = transform(match, source) {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }
}

/// Native Swift port of pangu.js 9.1.0 `spacingText`.
/// Source: https://github.com/vinta/pangu.js/tree/5071904474c3a3d71610d572be618744459ffa26
private enum PanguSpacing {
    private static let cjkRadicalsSupplement = "\\u2e80-\\u2eff"
    private static let kangxiRadicals = "\\u2f00-\\u2fdf"
    private static let hiragana = "\\u3040-\\u309f"
    private static let katakanaWithoutMiddleDot = "\\u30a0-\\u30fa\\u30fc-\\u30ff"
    private static let bopomofo = "\\u3100-\\u312f"
    private static let enclosedCJK = "\\u3200-\\u32ff"
    private static let unifiedExtensionA = "\\u3400-\\u4dbf"
    private static let unifiedIdeographs = "\\u4e00-\\u9fff"
    private static let compatibilityIdeographs = "\\uf900-\\ufaff"
    private static let greekAndCoptic = "\\u0370-\\u03ff"
    private static let latin1AfterNBSP = "\\u00a1-\\u00ff"
    private static let numberForms = "\\u2150-\\u218f"
    private static let dingbats = "\\u2700-\\u27bf"

    private static let cjk = cjkRadicalsSupplement + kangxiRadicals + hiragana
        + katakanaWithoutMiddleDot + bopomofo + enclosedCJK + unifiedExtensionA
        + unifiedIdeographs + compatibilityIdeographs
    private static let an = "A-Za-z0-9"
    private static let alphabet = "A-Za-z"
    private static let ansAfterCJK = alphabet + greekAndCoptic
        + "0-9@\\$%\\^&\\*\\-\\+\\\\=" + latin1AfterNBSP + numberForms + dingbats
    private static let ansBeforeCJK = alphabet + greekAndCoptic
        + "0-9\\$%\\^&\\*\\-\\+\\\\=" + latin1AfterNBSP + numberForms + dingbats

    private static let filePathDirectories = "home|root|usr|etc|var|opt|tmp|dev|mnt|proc|sys|bin|boot|lib|media|run|sbin|srv|node_modules|path|project|src|dist|test|tests|docs|templates|assets|public|static|config|scripts|tools|build|out|target|your|\\.claude|\\.git|\\.vscode"
    private static let filePathCharacters = #"[A-Za-z0-9_\-\.@\+\*]+"#
    private static let unixAbsolutePathSource = #"/(?:\.?(?:"# + filePathDirectories
        + #")|\.(?:[A-Za-z0-9_\-]+))(?:/"# + filePathCharacters + ")*"
    private static let unixRelativePathSource = #"(?:\./)?(?:"# + filePathDirectories
        + ")(?:/" + filePathCharacters + ")+"
    private static let windowsPathSource = #"[A-Z]:[\\](?:[A-Za-z0-9_\-. ]+[\\]?)+"#

    private enum Patterns {
        static let anyCJK = RegexSupport.regex("[\(cjk)]")
        static let dotsCJK = RegexSupport.regex("([\\.]{2,}|\\u2026)([\(cjk)])")
        static let cjkPunctuation = RegexSupport.regex("([\(cjk)])([!;,\\?:]+)(?=[\(cjk)\(an)])")
        static let punctuationCJK = RegexSupport.regex("([!;,\\?]+)(?=[\(cjk)])")
        static let cjkTilde = RegexSupport.regex("([\(cjk)])(~+)(?!=)(?=[\(cjk)\(an)])")
        static let cjkTildeEquals = RegexSupport.regex("([\(cjk)])(~=)")
        static let cjkPeriod = RegexSupport.regex("([\(cjk)])(\\.)(?![\(an)\\./])(?=[\(cjk)\(an)])")
        static let anPeriodCJK = RegexSupport.regex("([\(an)])(\\.)([\(cjk)])")
        static let anColonCJK = RegexSupport.regex("([\(an)])(:)([\(cjk)])")
        static let fixCJKColonANS = RegexSupport.regex("([\(cjk)]):([A-Z0-9\\(\\)])")

        static let cjkQuote = RegexSupport.regex("([\(cjk)])([`\"\\u05f4])")
        static let quoteCJK = RegexSupport.regex("([`\"\\u05f4])([\(cjk)])")
        static let fixQuoteAnyQuote = RegexSupport.regex("([`\"\\u05f4]+)[ ]*([\\s\\S]+?)[ ]*([`\"\\u05f4]+)")
        static let quoteAN = RegexSupport.regex("([\\u201d])([\(an)])")
        static let cjkQuoteAN = RegexSupport.regex("([\(cjk)])(\")([\(an)])")
        static let fixPossessiveSingleQuote = RegexSupport.regex("([\(an)\(cjk)])( )('s)")
        static let singleQuotePureCJK = RegexSupport.regex("(')([\(cjk)]+)(')")
        static let cjkSingleQuoteNotPossessive = RegexSupport.regex("([\(cjk)])('[^s])")
        static let singleQuoteCJK = RegexSupport.regex("(')([\(cjk)])")

        static let hashCJKHash = RegexSupport.regex("([\(cjk)])(#)([\(cjk)]+)(#)([\(cjk)])")
        static let cjkHash = RegexSupport.regex("([\(cjk)])(#([^ \\u00a0]))")
        static let hashCJK = RegexSupport.regex("(([^ \\u00a0])#)([\(cjk)])")
        static let cjkFinalHashtag = RegexSupport.regex("([^/])([\(cjk)])(#[A-Za-z0-9]+)$")

        static let compoundWord = RegexSupport.regex(#"\b(?:[A-Za-z0-9]*[a-z][A-Za-z0-9]*-[A-Za-z0-9]+|[A-Za-z0-9]+-[A-Za-z0-9]*[a-z][A-Za-z0-9]*|[A-Za-z]+-[0-9]+|[A-Za-z]+[0-9]+-[A-Za-z0-9]+)(?:-[A-Za-z0-9]+)*\b"#)
        static let singleLetterGradeCJK = RegexSupport.regex("(?<![A-Za-z0-9_])([\(alphabet)])([\\+\\-\\*])([\(cjk)])")
        static let cjkSignDigit = RegexSupport.regex("([\(cjk)])([\\+\\-])([0-9])")
        static let cjkHyphenFlag = RegexSupport.regex("([\(cjk)])(-)([a-z])(?![A-Za-z0-9_])")
        static let anPlusCJK = RegexSupport.regex("([\(an)])(\\+)([\(cjk)])")
        static let cjkOperatorANS = RegexSupport.regex("([\(cjk)])([\\+\\*=&\\-])([\(an)])")
        static let ansOperatorCJK = RegexSupport.regex("([\(an)])([\\*=&\\-])([\(cjk)])")
        static let cjkLessThan = RegexSupport.regex("([\(cjk)])(<)([\(an)])")
        static let lessThanCJK = RegexSupport.regex("([\(an)])(<)([\(cjk)])")
        static let cjkGreaterThan = RegexSupport.regex("([\(cjk)])(>)([\(an)])")
        static let greaterThanCJK = RegexSupport.regex("([\(an)])(>)([\(cjk)])")

        static let cjkUnixAbsolutePath = RegexSupport.regex("([\(cjk)])(\(unixAbsolutePathSource))")
        static let cjkUnixRelativePath = RegexSupport.regex("([\(cjk)])(\(unixRelativePathSource))")
        static let cjkWindowsPath = RegexSupport.regex("([\(cjk)])(\(windowsPathSource))")
        static let unixAbsolutePathSlashCJK = RegexSupport.regex("(\(unixAbsolutePathSource)/)([\(cjk)])")
        static let unixRelativePathSlashCJK = RegexSupport.regex("(\(unixRelativePathSource)/)([\(cjk)])")

        static let cjkSlashCJK = RegexSupport.regex("([\(cjk)])(/)([\(cjk)])")
        static let cjkSlashANS = RegexSupport.regex("([\(cjk)])(/)([\(an)])")
        static let ansSlashCJK = RegexSupport.regex("([\(an)])(/)([\(cjk)])")
        static let pipeCJKContact = RegexSupport.regex("[\(cjk)]\\||\\|[\(cjk)]")
        static let pipeSeparator = RegexSupport.regex(#"([^\s|])[ ]*(\|+)[ ]*(?=[^\s|])"#)
        static let plusCJKContact = RegexSupport.regex("[\(cjk)]\\+|\\+[\(cjk)]")
        static let plusSeparator = RegexSupport.regex(#"(?<=[^\s+])\+(?=[^\s+])"#)

        static let cjkLeftBracket = RegexSupport.regex("([\(cjk)])([\\(\\[\\{<>\\u201c])")
        static let rightBracketCJK = RegexSupport.regex("([\\)\\]\\}<>\\u201d])([\(cjk)])")
        static let ansCJKLeftQuotePair = RegexSupport.regex("([\(an)\(cjk)])[ ]*([\\u201c])([\(an)\(cjk)\\-_ ]+)([\\u201d])")
        static let leftQuotePairANSCJK = RegexSupport.regex("([\\u201c])([\(an)\(cjk)\\-_ ]+)([\\u201d])[ ]*([\(an)\(cjk)])")
        static let rightQuotePair = RegexSupport.regex("([\(an)\(cjk)])[ ]*([\\u201d])[ ]*([\(an)\(cjk)\\-_ ]+?)[ ]*([\\u201d])")
        static let anLeftBracketCandidate = RegexSupport.regex("([\(an)])([\\(\\[\\{])")
        static let rightBracketAN = RegexSupport.regex("([\\)\\]\\}])([\(an)])")

        static let cjkANS = RegexSupport.regex("([\(cjk)])([\(ansAfterCJK)])")
        static let ansCJK = RegexSupport.regex("([\(ansBeforeCJK)])([\(cjk)])")
        static let percentAlphabet = RegexSupport.regex("%([\(alphabet)])")
        static let middleDot = RegexSupport.regex("([ ]*)([\\u00b7\\u2022\\u2027])([ ]*)")

        static let htmlTag = RegexSupport.regex(#"</?[a-zA-Z][a-zA-Z0-9]*(?:\s+[^>]*)?>"#)
        static let closingHTMLTag = RegexSupport.regex(#"</([a-zA-Z][a-zA-Z0-9]*)"#)
        static let bareHTMLTag = RegexSupport.regex(#"^<([a-zA-Z][a-zA-Z0-9]*)\s*/?>$"#)
        static let htmlAttribute = RegexSupport.regex(#"(\w+)="([^"]*)""#)
        static let backtickContent = RegexSupport.regex(#"`([^`]+)`"#)
    }

    private struct PlaceholderStore {
        let prefix: String
        let start: String
        let end: String
        private(set) var items: [String] = []

        mutating func store(_ value: String) -> String {
            let index = items.count
            items.append(value)
            return "\(start)\(prefix)\(index)\(end)"
        }

        func restore(in text: String) -> String {
            guard !items.isEmpty else { return text }
            let pattern = RegexSupport.regex(
                NSRegularExpression.escapedPattern(for: start + prefix)
                    + "(\\d+)"
                    + NSRegularExpression.escapedPattern(for: end)
            )
            return RegexSupport.replaceMatches(pattern, in: text) { match, source in
                guard match.numberOfRanges > 1,
                      let index = Int(source.substring(with: match.range(at: 1))),
                      items.indices.contains(index)
                else { return nil }
                return items[index]
            }
        }
    }

    static func spacingText(_ text: String) -> String {
        guard (text as NSString).length > 1,
              Patterns.anyCJK.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ) != nil
        else { return text }

        var result = text
        var backticks = PlaceholderStore(prefix: "BACKTICK_CONTENT_", start: "\u{E004}", end: "\u{E005}")
        result = RegexSupport.replaceMatches(Patterns.backtickContent, in: result) { match, source in
            guard match.numberOfRanges > 1 else { return nil }
            return "`\(backticks.store(source.substring(with: match.range(at: 1))))`"
        }

        var htmlTags = PlaceholderStore(prefix: "HTML_TAG_", start: "\u{E000}", end: "\u{E001}")
        var mentionedTags = PlaceholderStore(prefix: "HTML_TAG_MENTION_", start: "\u{E002}", end: "\u{E003}")
        let hasHTML = result.contains("<")
        if hasHTML {
            let closedNames = closingHTMLTagNames(in: result)
            let voidTags: Set<String> = [
                "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                "param", "source", "track", "wbr",
            ]
            result = RegexSupport.replaceMatches(Patterns.htmlTag, in: result) { match, source in
                let tag = source.substring(with: match.range)
                if let name = capture(1, from: Patterns.bareHTMLTag, in: tag)?.lowercased(),
                   !voidTags.contains(name), !closedNames.contains(name) {
                    return mentionedTags.store(tag)
                }
                let processed = RegexSupport.replaceMatches(Patterns.htmlAttribute, in: tag) { attributeMatch, attributeSource in
                    guard attributeMatch.numberOfRanges > 2 else { return nil }
                    let name = attributeSource.substring(with: attributeMatch.range(at: 1))
                    let value = attributeSource.substring(with: attributeMatch.range(at: 2))
                    return "\(name)=\"\(spacingText(value))\""
                }
                return htmlTags.store(processed)
            }
        }

        result = RegexSupport.replace(Patterns.dotsCJK, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.cjkPunctuation, in: result, with: "$1$2 ")
        result = RegexSupport.replace(Patterns.punctuationCJK, in: result, with: "$1 ")
        result = RegexSupport.replace(Patterns.cjkTilde, in: result, with: "$1$2 ")
        result = RegexSupport.replace(Patterns.cjkTildeEquals, in: result, with: "$1 $2 ")
        result = RegexSupport.replace(Patterns.cjkPeriod, in: result, with: "$1$2 ")
        result = RegexSupport.replace(Patterns.anPeriodCJK, in: result, with: "$1$2 $3")
        result = RegexSupport.replace(Patterns.anColonCJK, in: result, with: "$1$2 $3")
        result = RegexSupport.replace(Patterns.fixCJKColonANS, in: result, with: "$1：$2")

        result = RegexSupport.replace(Patterns.cjkQuote, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.quoteCJK, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.fixQuoteAnyQuote, in: result, with: "$1$2$3")
        result = RegexSupport.replace(Patterns.quoteAN, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.cjkQuoteAN, in: result, with: "$1$2 $3")
        result = RegexSupport.replace(Patterns.fixPossessiveSingleQuote, in: result, with: "$1$3")

        var pureCJKSingleQuotes = PlaceholderStore(prefix: "SINGLE_QUOTE_CJK_", start: "\u{E030}", end: "\u{E031}")
        result = RegexSupport.replaceMatches(Patterns.singleQuotePureCJK, in: result) { match, source in
            pureCJKSingleQuotes.store(source.substring(with: match.range))
        }
        result = RegexSupport.replace(Patterns.cjkSingleQuoteNotPossessive, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.singleQuoteCJK, in: result, with: "$1 $2")
        result = pureCJKSingleQuotes.restore(in: result)

        if (result as NSString).length >= 5 {
            result = RegexSupport.replace(Patterns.hashCJKHash, in: result, with: "$1 $2$3$4 $5")
        }
        result = mapLines(result) { line in
            if line.filter({ $0 == "/" }).count <= 1 {
                var value = RegexSupport.replace(Patterns.cjkHash, in: line, with: "$1 $2")
                value = RegexSupport.replace(Patterns.hashCJK, in: value, with: "$1 $3")
                return value
            }
            return RegexSupport.replace(Patterns.cjkFinalHashtag, in: line, with: "$1$2 $3")
        }

        var compoundWords = PlaceholderStore(prefix: "COMPOUND_WORD_", start: "\u{E010}", end: "\u{E011}")
        result = RegexSupport.replaceMatches(Patterns.compoundWord, in: result) { match, source in
            compoundWords.store(source.substring(with: match.range))
        }
        result = RegexSupport.replace(Patterns.singleLetterGradeCJK, in: result, with: "$1$2 $3")
        result = RegexSupport.replace(Patterns.cjkSignDigit, in: result, with: "$1 $2$3")
        result = RegexSupport.replace(Patterns.cjkHyphenFlag, in: result, with: "$1 $2$3")
        result = RegexSupport.replace(Patterns.anPlusCJK, in: result, with: "$1$2 $3")
        result = RegexSupport.replace(Patterns.cjkOperatorANS, in: result, with: "$1 $2 $3")
        result = RegexSupport.replace(Patterns.ansOperatorCJK, in: result, with: "$1 $2 $3")
        result = RegexSupport.replace(Patterns.cjkLessThan, in: result, with: "$1 $2 $3")
        result = RegexSupport.replace(Patterns.lessThanCJK, in: result, with: "$1 $2 $3")
        result = RegexSupport.replace(Patterns.cjkGreaterThan, in: result, with: "$1 $2 $3")
        result = RegexSupport.replace(Patterns.greaterThanCJK, in: result, with: "$1 $2 $3")

        result = RegexSupport.replace(Patterns.cjkUnixAbsolutePath, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.cjkUnixRelativePath, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.cjkWindowsPath, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.unixAbsolutePathSlashCJK, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.unixRelativePathSlashCJK, in: result, with: "$1 $2")

        result = mapLines(result) { line in
            guard line.filter({ $0 == "/" }).count == 1 else { return line }
            var value = RegexSupport.replace(Patterns.cjkSlashCJK, in: line, with: "$1 $2 $3")
            value = RegexSupport.replace(Patterns.cjkSlashANS, in: value, with: "$1 $2 $3")
            value = RegexSupport.replace(Patterns.ansSlashCJK, in: value, with: "$1 $2 $3")
            return value
        }
        result = mapLines(result) { line in
            guard Patterns.pipeCJKContact.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) != nil else { return line }
            return RegexSupport.replace(Patterns.pipeSeparator, in: line, with: "$1 $2 ")
        }
        result = mapLines(result) { line in
            guard Patterns.plusCJKContact.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) != nil else { return line }
            return RegexSupport.replace(Patterns.plusSeparator, in: line, with: " + ")
        }
        result = RegexSupport.replace(Patterns.fixQuoteAnyQuote, in: result, with: "$1$2$3")
        result = compoundWords.restore(in: result)

        result = RegexSupport.replace(Patterns.cjkLeftBracket, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.rightBracketCJK, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.ansCJKLeftQuotePair, in: result, with: "$1 $2$3$4")
        result = RegexSupport.replace(Patterns.leftQuotePairANSCJK, in: result, with: "$1$2$3 $4")
        result = spacingRightQuotePairs(result)
        result = spacingANLeftBrackets(result)
        result = RegexSupport.replace(Patterns.rightBracketAN, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.cjkANS, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.ansCJK, in: result, with: "$1 $2")
        result = RegexSupport.replace(Patterns.percentAlphabet, in: result, with: "% $1")
        result = RegexSupport.replace(Patterns.middleDot, in: result, with: "・")
        result = fixBracketSpacing(result)

        if hasHTML {
            result = RegexSupport.replace(#"(["# + cjk + #"])(?=\uE002)"#, in: result, with: "$1 ")
            result = RegexSupport.replace(#"(?<=\uE003)(["# + cjk + #"])"#, in: result, with: " $1")
            result = mentionedTags.restore(in: result)
            result = htmlTags.restore(in: result)
        }
        return backticks.restore(in: result)
    }

    private static func mapLines(_ text: String, transform: (String) -> String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { transform(String($0)) }
            .joined(separator: "\n")
    }

    private static func closingHTMLTagNames(in text: String) -> Set<String> {
        let source = text as NSString
        return Set(Patterns.closingHTMLTag.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return source.substring(with: match.range(at: 1)).lowercased()
        })
    }

    private static func capture(
        _ group: Int,
        from regex: NSRegularExpression,
        in text: String
    ) -> String? {
        let source = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ), match.numberOfRanges > group, match.range(at: group).location != NSNotFound
        else { return nil }
        return source.substring(with: match.range(at: group))
    }

    /// Ports pangu.js's variable-length lookbehind for `CJK”text”` pairs.
    private static func spacingRightQuotePairs(_ text: String) -> String {
        RegexSupport.replaceMatches(Patterns.rightQuotePair, in: text) { match, source in
            let prefix = source.substring(to: match.range.location)
            let currentLine = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if let lastQuote = currentLine.last(where: { $0 == "“" || $0 == "”" }), lastQuote == "“" {
                return nil
            }
            return "\(source.substring(with: match.range(at: 1))) \(source.substring(with: match.range(at: 2)))\(source.substring(with: match.range(at: 3)))\(source.substring(with: match.range(at: 4)))"
        }
    }

    /// Keeps call parentheses tight for dotted names (`Math.floor(x)`) while
    /// spacing ordinary names (`foo (x)`), matching pangu.js without a variable lookbehind.
    private static func spacingANLeftBrackets(_ text: String) -> String {
        RegexSupport.replaceMatches(Patterns.anLeftBracketCandidate, in: text) { match, source in
            let start = match.range.location
            var index = start - 1
            while index >= 0 {
                let scalar = source.character(at: index)
                let isAN = (scalar >= 48 && scalar <= 57)
                    || (scalar >= 65 && scalar <= 90)
                    || (scalar >= 97 && scalar <= 122)
                if !isAN { break }
                index -= 1
            }
            if index >= 0, source.character(at: index) == 46 { return nil }
            return "\(source.substring(with: match.range(at: 1))) \(source.substring(with: match.range(at: 2)))"
        }
    }

    private static func fixBracketSpacing(_ text: String) -> String {
        let pairs: [(pattern: String, open: String, close: String)] = [
            (#"<([^<>]*)>"#, "<", ">"),
            (#"\(([^()]*)\)"#, "(", ")"),
            (#"\[([^\[\]]*)\]"#, "[", "]"),
            (#"\{([^{}]*)\}"#, "{", "}"),
        ]
        return pairs.reduce(text) { value, pair in
            let regex = RegexSupport.regex(pair.pattern)
            return RegexSupport.replaceMatches(regex, in: value) { match, source in
                guard match.numberOfRanges > 1 else { return nil }
                let inner = source.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: #"^ +| +$"#, with: "", options: .regularExpression)
                return pair.open + inner + pair.close
            }
        }
    }
}
