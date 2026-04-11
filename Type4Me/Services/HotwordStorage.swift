import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Hotword storage with two independent stores:
/// - **Built-in file** (`builtin-hotwords.json`): seeded from defaults, user-editable via Finder for bulk ops
/// - **User file** (`hotwords.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime (deduplicated, case-insensitive).
enum HotwordStorage {

    // MARK: - In-memory caches

    private static let cacheLock = NSLock()
    private static var cachedBuiltin: [String]?   // guarded by cacheLock
    private static var cachedUser: [String]?       // guarded by cacheLock

    // MARK: - File paths

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Type4Me")
    }

    /// Built-in hotwords file (seeded from defaults, user-editable for bulk ops)
    static var builtinFileURL: URL { appSupportDir.appendingPathComponent("builtin-hotwords.json") }

    /// User hotwords file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("hotwords.json") }

    // MARK: - Default hotwords (code-defined baseline)

    /// Version string for the built-in hotword list. Bump this when adding/removing defaults
    /// so the cloud boosting table gets updated on next app launch.
    static let builtinVersion = "2026.03.31"

    /// Common tech terms that ASR engines frequently mis-transcribe.
    /// Focused on AI/dev terms that benefit from hotword boosting.
    static let defaultHotwords: [String] = [
        // ── AI models & companies ──
        "Claude", "Claude Code", "GPT", "GPT-4", "GPT-4o", "GPT-5", "Gemini",
        "LLaMA", "Llama", "Anthropic", "OpenAI", "DeepSeek", "Qwen", "Qwen3",
        "Mistral", "Cohere", "Perplexity", "Midjourney", "Stable Diffusion",
        "Hugging Face", "xAI", "Grok", "Groq", "Copilot", "ChatGPT",
        "DALL-E", "Whisper", "Sora",

        // ── AI coding tools ──
        "Cursor", "Windsurf", "Cline", "Aider", "Devin", "Codex",
        "vibe coding", "MCP",

        // ── AI frameworks & infra ──
        "LangChain", "LlamaIndex", "CrewAI", "AutoGen", "Dify", "Coze",
        "Ollama", "vLLM", "ComfyUI", "ControlNet", "OpenRouter", "LiteLLM",

        // ── AI concepts ──
        "LLM", "RAG", "LoRA", "QLoRA", "RLHF", "DPO", "agentic",
        "multimodal", "fine-tune", "fine-tuning", "embedding", "tokenizer",
        "transformer", "quantization", "GGUF", "ONNX", "TTS", "ASR",

        // ── Dev tools ──
        "GitHub", "GitLab", "VS Code", "Docker", "Kubernetes",
        "Terraform", "Homebrew", "npm", "pip", "Vercel", "Netlify", "Supabase",
        "Firebase", "Redis", "PostgreSQL", "MongoDB", "Elasticsearch",
        "Nginx", "Pinecone", "ChromaDB", "Weaviate",

        // ── Programming terms ──
        "API", "SDK", "token", "prompt", "webhook", "microservice",
        "DevOps", "CI/CD", "GraphQL", "WebSocket", "REST", "OAuth", "JWT",
        "JSON", "DMG",

        // ── Frameworks & languages ──
        "React", "Next.js", "Vue", "Angular", "SwiftUI", "PyTorch", "TensorFlow",
        "Tailwind", "TypeScript", "JavaScript", "Rust", "Kotlin",
        "Flutter", "Django", "FastAPI", "Express", "Vite", "Nuxt", "SvelteKit",
        "Prisma", "Drizzle",

        // ── Hardware ──
        "NVIDIA", "CUDA", "GPU", "TPU",
    ]

    // MARK: - Initialization

    private static let migratedKey = "tf_hotwords_migrated_to_file_v2"
    private static let oldUDKey = "tf_hotwords"

    /// Migrates old UserDefaults hotwords to user file (one-time).
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else { return }
        let raw = UserDefaults.standard.string(forKey: oldUDKey) ?? ""
        let oldWords = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if !oldWords.isEmpty {
            save(oldWords)
        }
    }

    // MARK: - User file (Settings UI)

    static func load() -> [String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedUser { return cached }
        let result = readFile(userFileURL)
        cachedUser = result
        return result
    }

    static let didChangeNotification = Notification.Name("HotwordStorageDidChange")

    static func save(_ words: [String]) {
        writeFile(words, to: userFileURL)
        cacheLock.lock()
        cachedUser = nil
        cacheLock.unlock()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        SenseVoiceServerManager.syncHotwordsAndRestart()
        // Sync to Volcengine cloud table if configured
        VolcHotwordSyncManager.syncAfterEdit()
    }

    // MARK: - Built-in file (Finder editable)

    static func loadBuiltin() -> [String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedBuiltin { return cached }
        let result = readFile(builtinFileURL)
        cachedBuiltin = result
        return result
    }

    static func saveBuiltin(_ words: [String]) {
        writeFile(words, to: builtinFileURL)
        cacheLock.lock()
        cachedBuiltin = nil
        cacheLock.unlock()
        SenseVoiceServerManager.syncHotwordsAndRestart()
    }

    static func builtinCount() -> Int {
        return loadBuiltin().count
    }

    /// Reveal built-in hotwords file in Finder (creates empty file if missing).
    static func revealBuiltinInFinder() {
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            saveBuiltin([])
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([builtinFileURL])
        #endif
    }

    // MARK: - Effective (merge both stores)

    /// Returns the user's hotwords (managed via Settings UI).
    static func loadEffective() -> [String] {
        return load()
    }

    // MARK: - Cloud-compatible words

    /// Returns merged (builtin + user) words filtered for Volcengine cloud table compatibility.
    /// Removes words with special symbols (only letters, digits, spaces, CJK allowed), max 10 chars.
    static func loadCloudCompatible() -> [String] {
        let all = loadEffective()
        return all.filter { word in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 10 else { return false }
            // Only allow: letters, digits, spaces, CJK
            return trimmed.allSatisfy { ch in
                ch.isLetter || ch.isNumber || ch.isWhitespace || ch.isCJKUnifiedIdeograph
            }
        }
    }

    // MARK: - Finder

    /// Reveal user hotwords file in Finder.
    static func revealUserInFinder() {
        let url = userFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            save([])
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return words
    }

    private static func writeFile(_ words: [String], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(words) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
