import Foundation

/// Configuration synced from the Mac app to the iPhone app.
///
/// There is no server in between, so the payload travels as text: copied
/// through Universal Clipboard, or shown as one or more QR codes that the
/// iPhone scans. Version 2 carries any number of speech services and text
/// models (one of each marked active), the modes the user chose to sync, and
/// optionally the user's hotwords and snippets. Receivers that predate a
/// field ignore it.
public struct Type4MeTransferPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public struct Endpoint: Codable, Equatable, Sendable {
        /// Provider raw value as stored by the Mac app (`volcano`, `deepseek`, …).
        public var provider: String
        /// Credential fields, already resolved by the exporter: base URLs filled
        /// in, defaults applied, plus `_`-prefixed hints such as the thinking
        /// switch so the receiving side needs no provider tables.
        public var fields: [String: String]

        public init(provider: String, fields: [String: String]) {
            self.provider = provider
            self.fields = fields
        }

        enum CodingKeys: String, CodingKey {
            case provider = "p"
            case fields = "f"
        }
    }

    /// A dictation mode. Built-in kinds map onto the iPhone's own built-in
    /// modes; `custom` carries its prompt, where `{text}` marks the transcript.
    public struct Mode: Codable, Equatable, Sendable {
        public enum Kind {
            public static let quick = "quick"
            public static let formalWriting = "formalWriting"
            /// The Mac's Translation mode; `targetLanguage` picks the language.
            /// The raw value predates target choice and is kept so earlier
            /// syncs and iPhone libraries still match.
            public static let translation = "translateEnglish"
            public static let agentMode = "agentMode"
            /// Intelli Sense. The iPhone builds its prompt from the text
            /// field it can see, so nothing but the kind travels.
            public static let intelliSense = "intelliSense"
            public static let custom = "custom"
        }

        /// Stable across syncs, so syncing again updates instead of duplicating.
        public var id: String
        /// One of `Kind`; kept as a string so newer kinds still decode.
        public var kind: String
        /// nil keeps the receiver's localized built-in name.
        public var name: String?
        /// nil or empty keeps the receiver's default prompt for built-in kinds.
        public var prompt: String?
        /// Translation only: the Mac `TranslationLanguage` code (`en`, `ja`,
        /// `zh-Hans`, …). nil means English.
        public var targetLanguage: String?
        /// The mode's own punctuation, a Mac `ModePunctuationMode` raw value.
        /// nil follows the global text output setting.
        public var punctuation: String?
        /// Recognized text shorter than this many characters skips the text
        /// model. nil or 0 always runs it.
        public var shortTextExemption: Int?

        public init(
            id: String,
            kind: String,
            name: String?,
            prompt: String?,
            targetLanguage: String? = nil,
            punctuation: String? = nil,
            shortTextExemption: Int? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.prompt = prompt
            self.targetLanguage = targetLanguage
            self.punctuation = punctuation
            self.shortTextExemption = shortTextExemption
        }

        enum CodingKeys: String, CodingKey {
            case id = "i"
            case kind = "k"
            case name = "n"
            case prompt = "p"
            case targetLanguage = "g"
            case punctuation = "u"
            case shortTextExemption = "x"
        }
    }

    /// A snippet rule: speech matching `trigger` (ignoring case and spaces)
    /// becomes `replacement`. See `SnippetPattern`.
    public struct Snippet: Codable, Equatable, Hashable, Sendable {
        public var trigger: String
        public var replacement: String

        public init(trigger: String, replacement: String) {
            self.trigger = trigger
            self.replacement = replacement
        }

        enum CodingKeys: String, CodingKey {
            case trigger = "t"
            case replacement = "r"
        }
    }

    /// The Mac's global text output formatting, applied to every dictation.
    /// Values are the Mac's raw setting values, so newer ones still decode.
    public struct TextOutput: Codable, Equatable, Sendable {
        /// A Mac `CJKSpacingMode` raw value: `pangu`, `off` or `remove`.
        public var cjkSpacing: String?
        /// A Mac `TrailingPunctuationMode` raw value: `off`, `period` or `all`.
        public var trailingPunctuation: String?
        /// Uses 『』 in place of ‘’.
        public var cornerQuotes: Bool?

        public init(cjkSpacing: String?, trailingPunctuation: String?, cornerQuotes: Bool?) {
            self.cjkSpacing = cjkSpacing
            self.trailingPunctuation = trailingPunctuation
            self.cornerQuotes = cornerQuotes
        }

        enum CodingKeys: String, CodingKey {
            case cjkSpacing = "s"
            case trailingPunctuation = "p"
            case cornerQuotes = "q"
        }
    }

    public var version: Int
    /// The speech service the Mac uses by default; becomes the iPhone's active one.
    public var asr: Endpoint?
    /// Further speech services to keep on the iPhone, switchable there.
    public var asrProfiles: [Endpoint]?
    /// The text model the Mac uses by default; becomes the iPhone's active one.
    public var llm: Endpoint?
    /// Further text models to keep on the iPhone, switchable there.
    public var llmProfiles: [Endpoint]?
    public var modes: [Mode]?
    /// The user's hotwords, passed to the speech service as recognition hints.
    public var hotwords: [String]?
    /// The user's global snippets. Per-app snippets stay on the Mac: an iPhone
    /// keyboard can't tell which app it is typing into.
    public var snippets: [Snippet]?
    public var textOutput: TextOutput?
    /// Name of the Mac that produced the payload, shown on the import screen.
    public var sourceName: String?
    /// Seconds since 1970 when the payload was produced.
    public var createdAt: Int?

    public init(
        version: Int = Self.currentVersion,
        asr: Endpoint?,
        asrProfiles: [Endpoint]? = nil,
        llm: Endpoint?,
        llmProfiles: [Endpoint]? = nil,
        modes: [Mode]? = nil,
        hotwords: [String]? = nil,
        snippets: [Snippet]? = nil,
        textOutput: TextOutput? = nil,
        sourceName: String? = nil,
        createdAt: Int? = nil
    ) {
        self.version = version
        self.asr = asr
        self.asrProfiles = asrProfiles
        self.llm = llm
        self.llmProfiles = llmProfiles
        self.modes = modes
        self.hotwords = hotwords
        self.snippets = snippets
        self.textOutput = textOutput
        self.sourceName = sourceName
        self.createdAt = createdAt
    }

    /// Every speech service in the payload, the active one first, one per provider.
    public var allASRs: [Endpoint] {
        Self.unique([asr].compactMap { $0 } + (asrProfiles ?? []))
    }

    /// Every text model in the payload, the active one first, one per provider.
    public var allLLMs: [Endpoint] {
        Self.unique([llm].compactMap { $0 } + (llmProfiles ?? []))
    }

    private static func unique(_ endpoints: [Endpoint]) -> [Endpoint] {
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0.provider).inserted }
    }

    public var isEmpty: Bool {
        allASRs.isEmpty && allLLMs.isEmpty && (modes ?? []).isEmpty
            && (hotwords ?? []).isEmpty && (snippets ?? []).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case asr = "a"
        case asrProfiles = "as"
        case llm = "l"
        case llmProfiles = "ls"
        case modes = "m"
        case hotwords = "h"
        case snippets = "s"
        case textOutput = "o"
        case sourceName = "d"
        case createdAt = "t"
    }
}

public enum Type4MeTransferError: Error, Equatable, Sendable {
    /// Nothing that looks like a Type4Me configuration was found in the input.
    case notFound
    /// The marker was found but the body is truncated or corrupted.
    case corrupted
    /// Produced by a newer Mac app than this receiver understands.
    case unsupportedVersion(Int)
    /// Nothing to import.
    case empty
    /// One QR code of several; the rest still have to be scanned.
    case partial
}

public enum Type4MeTransferCodec {
    /// Version 1 text: plain JSON. Still accepted when importing.
    public static let textPrefix = "T4M1."
    /// Version 2 text: zlib-compressed JSON. What the Mac writes now.
    public static let compressedPrefix = "T4M2."
    /// One part of a version 2 text split across several QR codes:
    /// `T4MP.<group>.<index>.<total>.<chunk>`, index counting from 1.
    public static let partPrefix = "T4MP."
    public static let urlScheme = "type4me"
    public static let urlHost = "import"
    public static let urlQueryItem = "c"
    /// Characters of payload per QR code: about 1 KB with the URL, a QR
    /// version a phone still reads at a glance off a Mac screen.
    public static let defaultChunkSize = 1000

    public static func encodeText(_ payload: Type4MeTransferPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(payload)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return compressedPrefix + base64URLEncode(compressed)
    }

    /// `type4me://import?c=T4M2.…` — opens the iPhone app straight from a QR code.
    public static func encodeURL(_ payload: Type4MeTransferPayload) throws -> String {
        url(for: try encodeText(payload))
    }

    /// The QR codes to show for a payload: one when it fits, otherwise a
    /// numbered series that the Mac cycles through.
    public static func encodeFrames(_ payload: Type4MeTransferPayload, chunkSize: Int = defaultChunkSize) throws -> [String] {
        let text = try encodeText(payload)
        let body = String(text.dropFirst(compressedPrefix.count))
        guard body.count > chunkSize else { return [url(for: text)] }
        let group = groupID(for: body)
        let chunks = stride(from: 0, to: body.count, by: chunkSize).map { start -> String in
            let from = body.index(body.startIndex, offsetBy: start)
            let to = body.index(from, offsetBy: min(chunkSize, body.count - start))
            return String(body[from..<to])
        }
        return chunks.enumerated().map { index, chunk in
            url(for: "\(partPrefix)\(group).\(index + 1).\(chunks.count).\(chunk)")
        }
    }

    private static func url(for token: String) -> String {
        "\(urlScheme)://\(urlHost)?\(urlQueryItem)=" + token
    }

    /// Accepts the bare text, the URL form, or either one embedded in a longer
    /// paste (a chat message, a note with line breaks inserted by the sender).
    public static func decode(_ input: String) throws -> Type4MeTransferPayload {
        if Part(input) != nil { throw Type4MeTransferError.partial }
        guard let token = extractToken(from: input) else { throw Type4MeTransferError.notFound }
        let compressed = token.hasPrefix(compressedPrefix)
        let body = String(token.dropFirst(compressed ? compressedPrefix.count : textPrefix.count))
        guard !body.isEmpty, var data = base64URLDecode(body) else {
            throw Type4MeTransferError.corrupted
        }
        if compressed {
            guard let inflated = try? (data as NSData).decompressed(using: .zlib) as Data else {
                throw Type4MeTransferError.corrupted
            }
            data = inflated
        }
        let payload: Type4MeTransferPayload
        do {
            payload = try JSONDecoder().decode(Type4MeTransferPayload.self, from: data)
        } catch {
            throw Type4MeTransferError.corrupted
        }
        guard payload.version <= Type4MeTransferPayload.currentVersion else {
            throw Type4MeTransferError.unsupportedVersion(payload.version)
        }
        guard !payload.isEmpty else { throw Type4MeTransferError.empty }
        return payload
    }

    /// Whether the input contains something worth trying to decode, without
    /// decoding it. Used to light up the paste affordance.
    public static func containsToken(_ input: String) -> Bool {
        extractToken(from: input) != nil || Part(input) != nil
    }

    static func extractToken(from input: String) -> String? {
        // Messaging apps and notes wrap long lines; whitespace is never part
        // of the base64url alphabet, so it is safe to drop all of it.
        let decoded = compacted(input)
        for prefix in [compressedPrefix, textPrefix] {
            guard let range = decoded.range(of: prefix) else { continue }
            let body = decoded[range.upperBound...].prefix { isBase64URLCharacter($0) }
            return prefix + body
        }
        return nil
    }

    static func compacted(_ input: String) -> String {
        let compact = input.filter { !$0.isWhitespace }
        return compact.removingPercentEncoding ?? compact
    }

    /// One scanned part of a multi-code payload.
    public struct Part: Equatable, Sendable {
        public let group: String
        public let index: Int
        public let total: Int
        public let chunk: String

        public init?(_ input: String) {
            let text = Type4MeTransferCodec.compacted(input)
            guard let range = text.range(of: Type4MeTransferCodec.partPrefix) else { return nil }
            let fields = text[range.upperBound...].split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let index = Int(fields[1]), let total = Int(fields[2]),
                  total >= 1, total <= 99, (1...total).contains(index)
            else { return nil }
            let chunk = fields[3].prefix { Type4MeTransferCodec.isBase64URLCharacter($0) }
            guard !fields[0].isEmpty, !chunk.isEmpty else { return nil }
            group = String(fields[0])
            self.index = index
            self.total = total
            self.chunk = String(chunk)
        }
    }

    /// Short, stable ID shared by every part of one payload, so a scanner
    /// can tell when the Mac switched to a different selection.
    static func groupID(for body: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in body.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(String(hash, radix: 36).prefix(8))
    }

    static func isBase64URLCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// Collects the QR codes of one payload in any order until all are in.
///
/// Scanning keeps reading the same codes while the Mac cycles through them,
/// so duplicates are expected and ignored. A part from a different group
/// (the Mac selection changed) starts over.
public struct Type4MeTransferAssembler: Sendable {
    public enum Status: Equatable, Sendable {
        /// Not a Type4Me code.
        case ignored
        /// Parts collected so far.
        case progress(received: Set<Int>, total: Int)
        case complete(Type4MeTransferPayload)
        case failed(Type4MeTransferError)
    }

    public private(set) var group: String?
    public private(set) var total = 0
    private var chunks: [Int: String] = [:]

    public init() {}

    public var received: Set<Int> { Set(chunks.keys) }

    public mutating func reset() {
        group = nil
        total = 0
        chunks = [:]
    }

    public mutating func add(_ scanned: String) -> Status {
        guard let part = Type4MeTransferCodec.Part(scanned) else {
            // A single code holds the whole payload.
            guard Type4MeTransferCodec.extractToken(from: scanned) != nil else { return .ignored }
            do {
                return .complete(try Type4MeTransferCodec.decode(scanned))
            } catch let error as Type4MeTransferError {
                return .failed(error)
            } catch {
                return .failed(.corrupted)
            }
        }
        if part.group != group || part.total != total {
            reset()
            group = part.group
            total = part.total
        }
        chunks[part.index] = part.chunk
        guard chunks.count == total else { return .progress(received: received, total: total) }

        let body = (1...total).compactMap { chunks[$0] }.joined()
        do {
            let payload = try Type4MeTransferCodec.decode(Type4MeTransferCodec.compressedPrefix + body)
            return .complete(payload)
        } catch let error as Type4MeTransferError {
            reset()
            return .failed(error)
        } catch {
            reset()
            return .failed(.corrupted)
        }
    }
}

/// What the iPhone app can run today. The Mac exporter uses this to offer
/// only endpoints that will work after import.
public enum Type4MeTransferSupport {
    /// Every cloud speech service the Mac runs. On-device engines (Apple
    /// Speech, SenseVoice) and the deprecated Baidu one stay on the Mac.
    /// The first few are the Mac's recommended ones, in its order.
    public static let asrProviders: [String] = [
        "volcano", "mimo", "bailian", "soniox",
        "assemblyai", "azure", "cartesia", "deepgram", "elevenlabs", "gemini",
        "grok", "groq", "metaMuse", "mistral", "openai", "stepfun", "tencent", "custom",
    ]

    /// Cloud chat providers. Local gateways (Ollama, Magpie, Codex CLI) are
    /// excluded because they listen on the Mac, not the internet. All are
    /// OpenAI compatible except Claude, which uses Anthropic's Messages API.
    public static let llmProviders: [String] = [
        "doubao", "deepseek", "bailian", "kimi", "zhipu", "mimo",
        "minimaxCN", "minimaxIntl", "openrouter", "openai", "gemini", "claude", "custom",
    ]

    public static let llmFieldKeys = ["apiKey", "model", "baseURL", "reasoningEffort"]

    /// Hint fields the exporter adds next to the LLM credentials.
    public enum LLMHint {
        /// Value is the request field that turns thinking off: `thinking`,
        /// `enableThinking`, `reasoningEffort` or `reasoning`.
        public static let thinkingOff = "_thinkingOff"
        /// `1` when the provider needs `reasoning_split` (MiniMax).
        public static let reasoningSplit = "_reasoningSplit"
    }
}
