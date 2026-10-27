import Foundation
import Type4MeTransferCore

/// Builds the configuration the iPhone app syncs: the speech services, the
/// text models, the modes and the vocabulary the user picked.
///
/// Everything is resolved here (default base URLs, the Volcano model actually
/// in use, the thinking switch, translation targets). Speech services travel
/// as their config's own credentials, which the iPhone reads with the same
/// provider configs compiled from the Mac sources.
enum MobileConfigExporter {

    struct Candidate: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    /// ASR providers the iPhone app supports that have credentials on this Mac.
    static func asrCandidates() -> [Candidate] {
        Type4MeTransferSupport.asrProviders.compactMap { raw in
            guard let provider = ASRProvider(rawValue: raw),
                  asrEndpoint(for: provider) != nil
            else { return nil }
            return Candidate(id: raw, displayName: provider.displayName)
        }
    }

    /// LLM providers the iPhone app supports that have credentials on this Mac.
    static func llmCandidates() -> [Candidate] {
        Type4MeTransferSupport.llmProviders.compactMap { raw in
            guard let provider = LLMProvider(rawValue: raw),
                  llmEndpoint(for: provider) != nil
            else { return nil }
            return Candidate(id: raw, displayName: provider.displayName)
        }
    }

    /// The Mac's own default when the iPhone supports it, else the first one configured.
    static func preferredASR(in candidates: [Candidate]) -> String? {
        let selected = KeychainService.selectedASRProvider.rawValue
        return candidates.contains { $0.id == selected } ? selected : candidates.first?.id
    }

    static func preferredLLM(in candidates: [Candidate]) -> String? {
        let selected = KeychainService.selectedLLMProvider.rawValue
        return candidates.contains { $0.id == selected } ? selected : candidates.first?.id
    }

    /// Modes that make sense on the iPhone keyboard. Mac Action, Command
    /// Mode and Ask Anything need the Mac (tools, selected text, a panel).
    /// Intelli Sense travels: the iPhone keyboard sees the text around the
    /// cursor and the kind of field, though not which app it is in.
    static func modeCandidates() -> [Candidate] {
        ModeStorage().load().compactMap { mode in
            guard transferMode(for: mode) != nil else { return nil }
            return Candidate(id: mode.id.uuidString, displayName: mode.localizedDisplayName)
        }
    }

    /// `asrs` and `llms` in the order to keep; the defaults become the iPhone's active ones.
    static func makePayload(
        asrs: [String],
        defaultASR: String?,
        llms: [String],
        defaultLLM: String?,
        modes modeIDs: [String],
        hotwords: [String] = [],
        snippets: [Type4MeTransferPayload.Snippet] = []
    ) -> Type4MeTransferPayload? {
        let (asr, asrOthers) = split(
            asrs.compactMap { ASRProvider(rawValue: $0).flatMap(asrEndpoint(for:)) },
            active: defaultASR
        )
        let (llm, llmOthers) = split(
            llms.compactMap { LLMProvider(rawValue: $0).flatMap(llmEndpoint(for:)) },
            active: defaultLLM
        )
        let wanted = Set(modeIDs)
        let modes = ModeStorage().load()
            .filter { wanted.contains($0.id.uuidString) }
            .compactMap(transferMode(for:))
        guard asr != nil || llm != nil || !modes.isEmpty || !hotwords.isEmpty || !snippets.isEmpty
        else { return nil }
        return Type4MeTransferPayload(
            asr: asr,
            asrProfiles: asrOthers.isEmpty ? nil : asrOthers,
            llm: llm,
            llmProfiles: llmOthers.isEmpty ? nil : llmOthers,
            modes: modes.isEmpty ? nil : modes,
            hotwords: hotwords.isEmpty ? nil : hotwords,
            snippets: snippets.isEmpty ? nil : snippets,
            textOutput: textOutput(),
            sourceName: Host.current().localizedName,
            createdAt: Int(Date().timeIntervalSince1970)
        )
    }

    private static func split(
        _ endpoints: [Type4MeTransferPayload.Endpoint],
        active: String?
    ) -> (Type4MeTransferPayload.Endpoint?, [Type4MeTransferPayload.Endpoint]) {
        let first = endpoints.first { $0.provider == active } ?? endpoints.first
        return (first, endpoints.filter { $0.provider != first?.provider })
    }

    // MARK: - Vocabulary

    /// The hotwords from the Vocabulary page, without blanks or repeats.
    static func hotwords(from words: [String] = HotwordStorage.load()) -> [String] {
        var seen = Set<String>()
        return words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The global snippets from the Vocabulary page, in the order the Mac
    /// applies them. App-specific snippets stay on the Mac.
    static func snippets(
        from rules: [(trigger: String, value: String)] = SnippetStorage.load()
    ) -> [Type4MeTransferPayload.Snippet] {
        rules.compactMap { rule in
            let trigger = rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { return nil }
            return .init(trigger: trigger, replacement: rule.value)
        }
    }

    // MARK: - Text output

    /// The global formatting under Appearance › Text Output, as stored.
    static func textOutput(userDefaults: UserDefaults = .standard) -> Type4MeTransferPayload.TextOutput {
        Type4MeTransferPayload.TextOutput(
            cjkSpacing: CJKSpacingMode.current(userDefaults: userDefaults).rawValue,
            trailingPunctuation: userDefaults.string(forKey: "tf_stripTrailingPunctuation")
                .flatMap(TrailingPunctuationMode.init(rawValue:))?.rawValue ?? TrailingPunctuationMode.off.rawValue,
            cornerQuotes: userDefaults.object(forKey: CornerQuotePreference.storageKey) as? Bool
                ?? CornerQuotePreference.defaultValue
        )
    }

    // MARK: - Modes

    typealias TransferMode = Type4MeTransferPayload.Mode

    /// Shipped Mac modes that stay on the Mac. Of the modes Type4Me ships,
    /// only Intelli Sense, Quick, Translation, Voice Polish and Handle It suit
    /// the phone keyboard; the user's own prompt modes travel too.
    private static let macOnlyModeIDs = Set<UUID>([
        ProcessingMode.macActionId,
        ProcessingMode.selectionAskId,
        ProcessingMode.commandMode.id,
        ProcessingMode.promptOptimizeId,
        ProcessingMode.smartDirectId,
    ]).union(ProcessingMode.legacyTranslationModeIDs)

    static func transferMode(for mode: ProcessingMode) -> TransferMode? {
        guard var transfer = baseTransferMode(for: mode) else { return nil }
        // Defaults stay out, keeping the codes small.
        transfer.punctuation = mode.punctuationMode == .inherit ? nil : mode.punctuationMode.rawValue
        transfer.shortTextExemption = mode.shortTextExemption > 0 ? mode.shortTextExemption : nil
        return transfer
    }

    private static func baseTransferMode(for mode: ProcessingMode) -> TransferMode? {
        guard mode.executionKind == .recording, !macOnlyModeIDs.contains(mode.id) else { return nil }

        switch mode.id {
        case ProcessingMode.directId:
            return TransferMode(id: TransferMode.Kind.quick, kind: TransferMode.Kind.quick, name: nil, prompt: nil)
        case ProcessingMode.intelliSenseId:
            return TransferMode(id: TransferMode.Kind.intelliSense, kind: TransferMode.Kind.intelliSense, name: nil, prompt: nil)
        case ProcessingMode.formalWritingId:
            return builtIn(TransferMode.Kind.formalWriting, mode, defaultPrompt: ProcessingMode.formalWritingPromptTemplate)
        case ProcessingMode.agentModeId:
            return builtIn(TransferMode.Kind.agentMode, mode, defaultPrompt: ProcessingMode.agentModePromptTemplate)
        case ProcessingMode.translationModeId:
            // Same target the Mac translates into; the iPhone builds the
            // prompt from the same template.
            let target = mode.translationTargetLanguageCode.flatMap(TranslationLanguage.init(rawValue:)) ?? .english
            return TransferMode(
                id: TransferMode.Kind.translation,
                kind: TransferMode.Kind.translation,
                name: nil,
                prompt: nil,
                targetLanguage: target.rawValue
            )
        default:
            let prompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            return TransferMode(
                id: "mac-" + mode.id.uuidString.lowercased(),
                kind: TransferMode.Kind.custom,
                name: mode.localizedDisplayName,
                prompt: prompt
            )
        }
    }

    /// A Mac mode the iPhone also ships. An unedited prompt stays behind so
    /// the iPhone keeps its own default (Handle It's drops the selected-text
    /// and clipboard parts); an edited one travels.
    private static func builtIn(_ kind: String, _ mode: ProcessingMode, defaultPrompt: String) -> TransferMode {
        let prompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = prompt.isEmpty || prompt == defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return TransferMode(id: kind, kind: kind, name: nil, prompt: isDefault ? nil : prompt)
    }

    // MARK: - Endpoints

    static func asrEndpoint(for provider: ASRProvider) -> Type4MeTransferPayload.Endpoint? {
        guard let stored = KeychainService.loadASRCredentials(for: provider),
              let configType = ASRProviderRegistry.configType(for: provider),
              let config = configType.init(credentials: stored),
              config.isValid
        else { return nil }
        // The config's own credentials carry resolved values (Volcano's model
        // is never "auto": the iPhone has no quota probe to pick 2.0 or 1.0).
        var fields = config.toCredentials().filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if provider == .volcano, let tableID = VolcHotwordSyncManager.boostingTableID {
            fields["boostingTableID"] = tableID
        }
        guard !fields.isEmpty else { return nil }
        return .init(provider: provider.rawValue, fields: fields)
    }

    static func llmEndpoint(for provider: LLMProvider) -> Type4MeTransferPayload.Endpoint? {
        guard let stored = KeychainService.loadLLMCredentials(for: provider) else { return nil }
        var fields = pick(Type4MeTransferSupport.llmFieldKeys, from: stored)
        guard fields["apiKey"] != nil || !provider.requiresAPIKey else { return nil }

        if fields["baseURL"] == nil, !provider.defaultBaseURL.isEmpty {
            fields["baseURL"] = provider.defaultBaseURL
        }
        guard fields["baseURL"] != nil else { return nil }
        if fields["model"] == nil, let model = provider.modelOptions.first?.value {
            fields["model"] = model
        }

        if LLMThinkingPreference.isDisabled(for: provider),
           let field = provider.thinkingDisableField(for: fields["model"]),
           let hint = thinkingHint(field) {
            fields[Type4MeTransferSupport.LLMHint.thinkingOff] = hint
        }
        if provider.needsReasoningSplit {
            fields[Type4MeTransferSupport.LLMHint.reasoningSplit] = "1"
        }
        return .init(provider: provider.rawValue, fields: fields)
    }

    private static func thinkingHint(_ field: ThinkingDisableField) -> String? {
        switch field {
        case .thinking: return "thinking"
        case .enableThinking: return "enableThinking"
        case .reasoningEffort: return "reasoningEffort"
        case .reasoning: return "reasoning"
        // Ollama and Magpie are local to the Mac and never exported.
        case .think, .lowestReasoningEffort: return nil
        }
    }

    private static func pick(_ keys: [String], from values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            result[key] = value
        }
        return result
    }
}
