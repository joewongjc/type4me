import Foundation
import os

// MARK: - Data Models

struct VariantSuggestion: Identifiable {
    let id = UUID()
    let trigger: String
    let replacement: String
    var isSelected: Bool = true
    var isDuplicate: Bool = false
}

struct HotwordSuggestion: Identifiable {
    let id = UUID()
    let word: String
    var isSelected: Bool = true
    var isDuplicate: Bool = false
}

struct GenerationResult {
    var snippets: [VariantSuggestion]
    var hotwords: [HotwordSuggestion]
    var hotwordReason: String
}

// MARK: - Error

enum GenerationError: LocalizedError {
    case noLLMConfigured
    case llmFailed(String)
    case parseFailed
    #if HAS_CLOUD_SUBSCRIPTION
    case paidOnly
    #endif

    var errorDescription: String? {
        switch self {
        case .noLLMConfigured:
            return L("未配置 LLM，请先在设置中配置", "No LLM configured. Please set up in Settings.")
        case .llmFailed(let detail):
            return L("LLM 调用失败: \(detail)", "LLM call failed: \(detail)")
        case .parseFailed:
            return L("无法解析 LLM 返回结果", "Failed to parse LLM response")
        #if HAS_CLOUD_SUBSCRIPTION
        case .paidOnly:
            return L("此功能需要 Type4Me Cloud 付费订阅", "This feature requires a paid Type4Me Cloud subscription")
        #endif
        }
    }
}

// MARK: - Generator

actor ASRVariantGenerator {

    private let logger = Logger(subsystem: "com.type4me.llm", category: "ASRVariantGenerator")

    // MARK: - Main entry

    func generate(wrong: String, correct: String) async throws -> GenerationResult {
        #if HAS_CLOUD_SUBSCRIPTION
        if let token = await CloudAuthManager.shared.accessToken() {
            do {
                let result = try await generateViaCloud(wrong: wrong, correct: correct, token: token)
                let deduped = deduplicate(result)
                logger.info("Cloud: \(deduped.snippets.count) snippets, \(deduped.hotwords.count) hotwords")
                return deduped
            } catch GenerationError.paidOnly {
                logger.info("Cloud returned paid-only, trying local LLM")
            } catch {
                logger.warning("Cloud failed: \(error.localizedDescription), trying local LLM")
            }
        }
        #endif

        guard let config = KeychainService.loadLLMConfig() else {
            throw GenerationError.noLLMConfigured
        }

        let provider = KeychainService.selectedLLMProvider
        let client: any LLMClient = provider == .claude
            ? ClaudeChatClient()
            : DoubaoChatClient(provider: provider)

        let prompt = buildPrompt(wrong: wrong, correct: correct)
        logger.info("Local LLM: '\(wrong)' → '\(correct)'")

        let response: String
        do {
            response = try await client.process(text: " ", prompt: prompt, config: config)
        } catch {
            logger.error("Local LLM failed: \(error.localizedDescription)")
            throw GenerationError.llmFailed(error.localizedDescription)
        }

        guard let result = parseResponse(response, correct: correct) else {
            logger.error("Failed to parse: \(response.prefix(200))")
            throw GenerationError.parseFailed
        }

        let deduped = deduplicate(result)
        logger.info("Local: \(deduped.snippets.count) snippets, \(deduped.hotwords.count) hotwords")
        return deduped
    }

    #if HAS_CLOUD_SUBSCRIPTION
    // MARK: - Cloud Generation

    private func generateViaCloud(wrong: String, correct: String, token: String) async throws -> GenerationResult {
        let endpoint = CloudConfig.apiEndpoint + "/api/vocab-suggest"

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45

        struct VocabRequest: Encodable {
            let correct: String
            let wrong: String
        }
        request.httpBody = try JSONEncoder().encode(VocabRequest(correct: correct, wrong: wrong))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.llmFailed("network error")
        }

        if http.statusCode == 403 {
            throw GenerationError.paidOnly
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GenerationError.llmFailed("server \(http.statusCode): \(body)")
        }

        struct CloudVocabResponse: Decodable {
            let snippets: [CloudSnippet]?
            let hotwords: [String]?
            let hotword_reason: String?
            let error: String?
        }
        struct CloudSnippet: Decodable {
            let trigger: String
            let replacement: String
        }

        let resp = try JSONDecoder().decode(CloudVocabResponse.self, from: data)
        if let error = resp.error, !error.isEmpty {
            throw GenerationError.llmFailed(error)
        }

        let snippets = (resp.snippets ?? [])
            .filter { !$0.trigger.isEmpty && $0.trigger.lowercased() != correct.lowercased() }
            .map { VariantSuggestion(trigger: $0.trigger, replacement: $0.replacement) }

        let hotwords = (resp.hotwords ?? [])
            .filter { !$0.isEmpty }
            .map { HotwordSuggestion(word: $0) }

        return GenerationResult(
            snippets: snippets,
            hotwords: hotwords,
            hotwordReason: resp.hotword_reason ?? ""
        )
    }
    #endif

    // MARK: - LLM Prompt

    func buildPrompt(wrong: String, correct: String) -> String {
        """
        You are an ASR (speech recognition) error correction expert. \
        A user spoke "\(correct)" but the ASR engine transcribed it as "\(wrong)".

        Tasks:
        1. Generate 3-8 plausible ASR error variants for "\(correct)" — different ways an ASR engine \
        might mis-transcribe this word/phrase. Include "\(wrong)" itself as one of the variants. \
        Consider: homophones, phonetically similar words, spacing errors, partial recognition, \
        CJK/Latin boundary mistakes, and common ASR model confusions.

        2. Judge whether "\(correct)" should be added as an ASR hotword (a term that benefits from \
        boosted recognition priority). Hotwords are typically: proper nouns, technical jargon, \
        brand names, or domain-specific terms that ASR engines frequently miss. \
        Common everyday words should NOT be hotwords.

        Respond with ONLY pure JSON, no markdown fences, no explanation:
        {
          "snippets": [
            {"trigger": "错误形式1", "replacement": "\(correct)"},
            {"trigger": "错误形式2", "replacement": "\(correct)"}
          ],
          "hotwords": ["\(correct)"],
          "hotword_reason": "brief reason why it should/shouldn't be a hotword"
        }

        If "\(correct)" should NOT be a hotword, return "hotwords": [].
        Each snippet trigger must differ from the replacement. Do not include the correct form as a trigger.
        """
    }

    // MARK: - Local LLM Parse

    func parseResponse(_ response: String, correct: String) -> GenerationResult? {
        guard let match = response.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
              let data = response[match].data(using: .utf8)
        else { return nil }

        struct RawResponse: Decodable {
            let snippets: [RawSnippet]
            let hotwords: [String]?
            let hotword_reason: String?
        }
        struct RawSnippet: Decodable {
            let trigger: String
            let replacement: String
        }

        guard let raw = try? JSONDecoder().decode(RawResponse.self, from: data) else {
            return nil
        }

        let snippets = raw.snippets
            .filter { !$0.trigger.isEmpty && $0.trigger.lowercased() != correct.lowercased() }
            .map { VariantSuggestion(trigger: $0.trigger, replacement: $0.replacement) }

        let hotwords = (raw.hotwords ?? [])
            .filter { !$0.isEmpty }
            .map { HotwordSuggestion(word: $0) }

        return GenerationResult(
            snippets: snippets,
            hotwords: hotwords,
            hotwordReason: raw.hotword_reason ?? ""
        )
    }

    // MARK: - Deduplicate

    func deduplicate(_ result: GenerationResult) -> GenerationResult {
        func norm(_ s: String) -> String {
            s.filter { !$0.isWhitespace }.lowercased()
        }

        let userSnippets = SnippetStorage.load()
        let builtinSnippets = SnippetStorage.loadBuiltin()
        let existingTriggers = Set(
            (userSnippets + builtinSnippets).map { norm($0.trigger) }
        )

        var snippets = result.snippets
        for i in snippets.indices {
            if existingTriggers.contains(norm(snippets[i].trigger)) {
                snippets[i].isDuplicate = true
                snippets[i].isSelected = false
            }
        }

        let userHotwords = HotwordStorage.load()
        let builtinHotwords = HotwordStorage.loadBuiltin()
        let existingHotwords = Set(
            (userHotwords + builtinHotwords).map { $0.lowercased() }
        )

        var hotwords = result.hotwords
        for i in hotwords.indices {
            if existingHotwords.contains(hotwords[i].word.lowercased()) {
                hotwords[i].isDuplicate = true
                hotwords[i].isSelected = false
            }
        }

        return GenerationResult(
            snippets: snippets,
            hotwords: hotwords,
            hotwordReason: result.hotwordReason
        )
    }
}
