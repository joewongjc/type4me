import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Snippet replacement with two independent stores:
/// - **Built-in file** (`builtin-snippets.json`): seeded from defaults, user-editable via Finder for bulk ops
/// - **User file** (`snippets.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime; user entries override built-in on trigger conflict.
enum SnippetStorage {

    // MARK: - In-memory caches

    private static let fileCacheLock = NSLock()
    private static var cachedBuiltin: [(trigger: String, value: String)]?  // guarded by fileCacheLock
    private static var cachedUser: [(trigger: String, value: String)]?     // guarded by fileCacheLock

    // MARK: - File paths

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Type4Me")
    }

    /// Built-in snippets file (seeded from defaults, user-editable for bulk ops)
    static var builtinFileURL: URL { appSupportDir.appendingPathComponent("builtin-snippets.json") }

    /// User snippets file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("snippets.json") }

    // MARK: - Codable model

    private struct Entry: Codable {
        let trigger: String
        let replacement: String
    }

    // MARK: - Default snippets (used for initial seeding)

    /// Default ASR correction mappings. Seeded into builtin-snippets.json on first launch.
    /// Triggers are matched case-insensitively and space-insensitively via `buildFlexPattern`.
    ///
    /// Verified against: Volcengine Seed ASR 2.0, Qwen3-ASR 0.6B/1.7B, SenseVoice-Small.
    static let defaultSnippets: [(trigger: String, value: String)] = [

        // ── vibe coding (ASR 几乎必错) ──
        ("web coding",      "vibe coding"),
        ("webb coding",     "vibe coding"),
        ("vab coding",      "vibe coding"),
        ("vabe coding",     "vibe coding"),
        ("vibes coding",    "vibe coding"),
        ("Vipcoding",       "vibe coding"),
        ("vipe coding",     "vibe coding"),
        ("vb coding",       "vibe coding"),
        ("vib coding",      "vibe coding"),
        ("va coding",       "vibe coding"),
        ("vivcoding",       "vibe coding"),
        ("wife coding",     "vibe coding"),

        // ── Claude ──
        ("Cloud Code",      "Claude Code"),
        ("clod",            "Claude"),
        ("clawed",          "Claude"),
        ("claud",           "Claude"),

        // ── Anthropic ──
        ("Asthropic",       "Anthropic"),
        ("Anthropropic",    "Anthropic"),
        ("Anthropick",      "Anthropic"),
        ("Anthrobic",       "Anthropic"),
        ("and tropic",      "Anthropic"),
        ("an tropic",       "Anthropic"),
        ("anthrophic",      "Anthropic"),

        // ── ChatGPT ──
        ("chat GPT",        "ChatGPT"),

        // ── DeepSeek ──
        ("deepse",          "DeepSeek"),
        ("deep sick",       "DeepSeek"),
        ("deep seek",       "DeepSeek"),
        ("deep sec",        "DeepSeek"),

        // ── Gemini ──
        ("jiminy",          "Gemini"),
        ("gem any",         "Gemini"),

        // ── Qwen ──
        ("Queen三",         "Qwen3"),
        ("Queen 三",        "Qwen3"),
        ("Queen3",          "Qwen3"),
        ("Queen 3",         "Qwen3"),
        ("qun三",           "Qwen3"),
        ("Qu3",             "Qwen3"),
        ("Queen三点五",     "Qwen3.5"),
        ("Queen 3.5",       "Qwen3.5"),
        ("quin三点五",      "Qwen3.5"),
        ("qun三点五",       "Qwen3.5"),
        ("quin三点",        "Qwen3"),

        // ── Grok ──
        ("grock",           "Grok"),

        // ── Llama / Ollama ──
        ("ELMA",            "Llama"),
        ("OELMA",           "Ollama"),

        // ── Midjourney / Copilot / Perplexity ──
        ("mid journey",     "Midjourney"),
        ("co pilot",        "Copilot"),
        ("perplex city",    "Perplexity"),

        // ── Hugging Face ──
        ("hugging phase",   "Hugging Face"),
        ("hug and face",    "Hugging Face"),

        // ── Codex ──
        ("codecs",          "Codex"),
        ("CodeX",           "Codex"),
        ("Codec",           "Codex"),

        // ── JSON ──
        ("Jason",           "JSON"),

        // ── fine-tuning ──
        ("finight tuning",  "fine-tuning"),
        ("find tuning",     "fine-tuning"),
        ("fine tuning",     "fine-tuning"),
        ("fine tune",       "fine-tune"),

        // ── LoRA / QLoRA ──
        ("lore a",          "LoRA"),
        ("lor a",           "LoRA"),
        ("Q lore a",        "QLoRA"),

        // ── agentic ──
        ("a genetic",       "agentic"),
        ("a gentic",        "agentic"),

        // ── multimodal / multi-agent ──
        ("multi modal",     "multimodal"),
        ("multi agent",     "multi-agent"),
        ("multiag",         "multi-agent"),

        // ── few-shot / zero-shot / in-context learning ──
        ("few shot",        "few-shot"),
        ("zero shot",       "zero-shot"),
        ("in context learning", "in-context learning"),

        // ── embedding / context window ──
        ("imbedding",       "embedding"),
        ("contexwin",       "context window"),
        ("context win",     "context window"),

        // ── LangChain / LlamaIndex ──
        ("long chain",      "LangChain"),
        ("long train",      "LangChain"),
        ("llama index",     "LlamaIndex"),
        ("lama index",      "LlamaIndex"),

        // ── AI frameworks (CrewAI, AutoGen, ComfyUI, ControlNet) ──
        ("crew AI",         "CrewAI"),
        ("auto gen",        "AutoGen"),
        ("auto Jen",        "AutoGen"),
        ("comfy UI",        "ComfyUI"),
        ("control net",     "ControlNet"),

        // ── AI coding tools ──
        ("wind surf",       "Windsurf"),
        ("Klein",           "Cline"),
        ("C line",          "Cline"),
        ("aid her",         "Aider"),
        ("open router",     "OpenRouter"),
        ("light LLM",       "LiteLLM"),
        ("lite LLM",        "LiteLLM"),
        ("VLLM",            "vLLM"),
        ("llama CPP",       "llama.cpp"),
        ("curser",          "Cursor"),
        ("克色",            "Cursor"),

        // ── Dev tools ──
        ("get hub",         "GitHub"),
        ("git hub",         "GitHub"),
        ("VS code",         "VS Code"),
        ("Kubanetes",       "Kubernetes"),
        ("Kubenetes",       "Kubernetes"),
        ("Nextjs",          "Next.js"),
        ("type script",     "TypeScript"),
        ("typepescript",    "TypeScript"),
        ("graph QL",        "GraphQL"),
        ("web socket",      "WebSocket"),
        ("pinecom",         "Pinecone"),

        // ── Infra & formats ──
        ("DM g",            "DMG"),
        ("verse cell",      "Vercel"),
        ("verse L",         "Vercel"),
        ("super base",      "Supabase"),
        ("cloud flare",     "Cloudflare"),
        ("cloud flair",     "Cloudflare"),
        ("N video",         "NVIDIA"),
        ("onyx",            "ONNX"),
    ]

    // MARK: - Initialization

    private static let migratedKey = "tf_snippets_migrated_to_file_v2"
    private static let oldUDKey = "tf_snippets"

    /// Migrates old UserDefaults snippets to user file (one-time).
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else { return }
        guard let data = UserDefaults.standard.data(forKey: oldUDKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data)
        else { return }

        let oldSnippets = pairs.compactMap { pair -> (trigger: String, value: String)? in
            guard pair.count == 2 else { return nil }
            return (trigger: pair[0], value: pair[1])
        }

        if !oldSnippets.isEmpty {
            save(oldSnippets)
        }
    }

    // MARK: - User file (Settings UI)

    static func load() -> [(trigger: String, value: String)] {
        fileCacheLock.lock()
        defer { fileCacheLock.unlock() }
        if let cached = cachedUser { return cached }
        let result = readFile(userFileURL)
        cachedUser = result
        return result
    }

    static let didChangeNotification = Notification.Name("SnippetStorageDidChange")

    static func save(_ snippets: [(trigger: String, value: String)]) {
        writeFile(snippets, to: userFileURL)
        invalidateCache()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Built-in file (Finder editable)

    static func loadBuiltin() -> [(trigger: String, value: String)] {
        fileCacheLock.lock()
        defer { fileCacheLock.unlock() }
        if let cached = cachedBuiltin { return cached }
        let result = readFile(builtinFileURL)
        cachedBuiltin = result
        return result
    }

    static func saveBuiltin(_ snippets: [(trigger: String, value: String)]) {
        writeFile(snippets, to: builtinFileURL)
        invalidateCache()
    }

    static func builtinCount() -> Int {
        return loadBuiltin().count
    }

    /// Reveal built-in snippets file in Finder.
    static func revealBuiltinInFinder() {
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            saveBuiltin(defaultSnippets)
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([builtinFileURL])
        #endif
    }

    // MARK: - App-specific snippets

    /// Registered app for per-app snippet overrides.
    struct AppInfo: Codable, Identifiable, Equatable {
        let bundleId: String
        let name: String
        var id: String { bundleId }
    }

    // MARK: - App-specific file paths

    private static var appSnippetsDir: URL {
        appSupportDir.appendingPathComponent("app-snippets")
    }

    private static var registryFileURL: URL {
        appSnippetsDir.appendingPathComponent("registry.json")
    }

    private static func appSnippetFileURL(bundleId: String) -> URL {
        appSnippetsDir.appendingPathComponent("\(bundleId).json")
    }

    // MARK: - Registry CRUD

    static func loadRegistry() -> [AppInfo] {
        guard let data = try? Data(contentsOf: registryFileURL),
              let apps = try? JSONDecoder().decode([AppInfo].self, from: data)
        else { return [] }
        return apps
    }

    static func saveRegistry(_ apps: [AppInfo]) {
        let dir = registryFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(apps) else { return }
        try? data.write(to: registryFileURL, options: .atomic)
    }

    static func addApp(_ app: AppInfo) {
        var apps = loadRegistry()
        guard !apps.contains(where: { $0.bundleId == app.bundleId }) else { return }
        apps.append(app)
        saveRegistry(apps)
    }

    static func removeApp(bundleId: String) {
        var apps = loadRegistry()
        apps.removeAll { $0.bundleId == bundleId }
        saveRegistry(apps)
        // Delete the per-app snippet file
        try? FileManager.default.removeItem(at: appSnippetFileURL(bundleId: bundleId))
        // Invalidate this app's compiled cache
        appCacheLock.withLock { $0.removeValue(forKey: bundleId) }
    }

    // MARK: - Per-app snippet load/save

    static func loadAppSnippets(bundleId: String) -> [(trigger: String, value: String)] {
        return readFile(appSnippetFileURL(bundleId: bundleId))
    }

    static func saveAppSnippets(_ snippets: [(trigger: String, value: String)], bundleId: String) {
        writeFile(snippets, to: appSnippetFileURL(bundleId: bundleId))
        appCacheLock.withLock { $0.removeValue(forKey: bundleId) }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Compiled cache

    private struct CompiledRule {
        let regex: NSRegularExpression
        let pattern: String   // original flex pattern (for conflict detection)
        let template: String  // pre-escaped replacement
    }

    /// Thread-safe compiled rules cache for global snippets. Rebuilt only when snippets change.
    private static let cacheLock = OSAllocatedUnfairLock(initialState: [CompiledRule]?(nil))

    /// Thread-safe compiled rules cache for per-app snippets, keyed by bundleId.
    private static let appCacheLock = OSAllocatedUnfairLock(initialState: [String: [CompiledRule]]())

    /// Call after saving either file to force recompilation on next apply.
    static func invalidateCache() {
        cacheLock.withLock { $0 = nil }
        appCacheLock.withLock { $0.removeAll() }
        fileCacheLock.lock()
        cachedBuiltin = nil
        cachedUser = nil
        fileCacheLock.unlock()
    }

    private static func compiledRules() -> [CompiledRule] {
        if let cached = cacheLock.withLock({ $0 }) { return cached }
        let allSnippets = load()

        let rules = allSnippets.compactMap { snippet -> CompiledRule? in
            let pattern = buildFlexPattern(snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return CompiledRule(regex: regex, pattern: pattern, template: NSRegularExpression.escapedTemplate(for: snippet.value))
        }
        cacheLock.withLock { $0 = rules }
        return rules
    }

    private static func compiledAppRules(bundleId: String) -> [CompiledRule] {
        if let cached = appCacheLock.withLock({ $0[bundleId] }) { return cached }
        let snippets = loadAppSnippets(bundleId: bundleId)

        let rules = snippets.compactMap { snippet -> CompiledRule? in
            let pattern = buildFlexPattern(snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return CompiledRule(regex: regex, pattern: pattern, template: NSRegularExpression.escapedTemplate(for: snippet.value))
        }
        appCacheLock.withLock { $0[bundleId] = rules }
        return rules
    }

    // MARK: - Apply (merge both stores)

    /// Apply built-in + user snippets. User entries override built-in on trigger conflict.
    static func applyEffective(to text: String) -> String {
        var result = text
        for rule in compiledRules() {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    /// Apply global + app-specific snippets. App rules win on trigger conflict.
    static func applyEffective(to text: String, bundleId: String?) -> String {
        guard let bundleId, !bundleId.isEmpty else { return applyEffective(to: text) }

        let appRules = compiledAppRules(bundleId: bundleId)
        guard !appRules.isEmpty else { return applyEffective(to: text) }

        // Collect app rule patterns for conflict detection
        let appPatterns = Set(appRules.map(\.pattern))

        // Apply global rules first, skipping any that conflict with app rules
        var result = text
        for rule in compiledRules() {
            if appPatterns.contains(rule.pattern) { continue }
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }

        // Then apply app-specific rules (higher priority)
        for rule in appRules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    // MARK: - Pattern building

    /// Builds a regex that matches the trigger case-insensitively and space-insensitively.
    /// Strips all whitespace from trigger, then inserts `\s*` between each character.
    /// Uses ASCII-only word boundaries (not `\b`) so CJK/Latin boundaries work correctly.
    private static func buildFlexPattern(_ trigger: String) -> String {
        let chars = trigger.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return NSRegularExpression.escapedPattern(for: trigger) }
        let core = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
        return "(?<![a-zA-Z0-9])" + core + "(?![a-zA-Z0-9])"
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [(trigger: String, value: String)] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.map { (trigger: $0.trigger, value: $0.replacement) }
    }

    private static func writeFile(_ snippets: [(trigger: String, value: String)], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = snippets.map { Entry(trigger: $0.trigger, replacement: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
