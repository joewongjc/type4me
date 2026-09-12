import Foundation

struct ModeStorage {

    let fileURL: URL
    let userDefaults: UserDefaults

    init(fileURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let url = fileURL {
            self.fileURL = url
        } else {
            let appSupport = AppDataLocation.directory
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            self.fileURL = appSupport.appendingPathComponent("modes.json")
        }
    }

    func save(_ modes: [ProcessingMode]) throws {
        let data = try JSONEncoder().encode(modes)
        try data.write(to: fileURL, options: .atomic)
    }

    func load() -> [ProcessingMode] {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([ProcessingMode].self, from: data),
              !saved.isEmpty
        else {
            return ProcessingMode.defaults
        }

        // Migrate legacy built-in flags for default modes, and drop unknown built-ins.
        var result = saved.compactMap { mode -> ProcessingMode? in
            // Legacy translation records are user data. Preserve every field,
            // including old built-in flags, prompts, bindings, and ordering.
            if ProcessingMode.legacyTranslationModeIDs.contains(mode.id) {
                return mode
            }
            if mode.id == ProcessingMode.directId {
                var d = ProcessingMode.direct
                d.hotkeyBindings = mode.hotkeyBindings
                d.manualInputHotkey = mode.manualInputHotkey
                d.shortTextExemption = mode.shortTextExemption
                d.punctuationMode = mode.punctuationMode
                return d
            }
            if mode.id == ProcessingMode.intelliSenseId {
                var d = ProcessingMode.intelliSense
                d.hotkeyBindings = mode.hotkeyBindings
                d.manualInputHotkey = mode.manualInputHotkey
                d.shortTextExemption = mode.shortTextExemption
                d.punctuationMode = mode.punctuationMode
                return d
            }
            if mode.id == ProcessingMode.smartDirectId {
                return migrateDefaultMode(mode, fallback: .smartDirect)
            }
            if mode.id == ProcessingMode.formalWritingId {
                let legacyPrompts: Set<String> = [
                    ProcessingMode.legacyFormalWritingPromptTemplate,
                    ProcessingMode.previousFormalWritingPromptTemplate,
                ]
                // Also detect legacy prompts by unique substrings:
                // - v3: "内容包含多个要点时" (before point-count rewrite)
                // - v4: "## 结构化规则\n" without priority declaration (before single-numbering fix)
                let isV4 = mode.prompt.contains("## 结构化规则\n")
                    && !mode.prompt.contains("优先于轻编辑原则")
                let isLegacy = legacyPrompts.contains(mode.prompt)
                    || mode.prompt.contains("内容包含多个要点时")
                    || isV4
                var d = ProcessingMode.formalWriting
                d.hotkeyBindings = mode.hotkeyBindings
                d.manualInputHotkey = mode.manualInputHotkey
                d.description = mode.description
                d.shortTextExemption = mode.shortTextExemption
                d.punctuationMode = mode.punctuationMode
                // If user customized the prompt, keep theirs
                if !isLegacy {
                    d.name = mode.name
                    d.processingLabel = mode.processingLabel
                    d.prompt = mode.prompt
                }
                return d
            }
            if mode.id == ProcessingMode.selectionAskId {
                var d = ProcessingMode.selectionAsk
                d.hotkeyBindings = mode.hotkeyBindings
                d.manualInputHotkey = mode.manualInputHotkey
                d.punctuationMode = mode.punctuationMode
                if mode.prompt != ProcessingMode.selectionAsk.prompt,
                   !selectionAskPromptIsLegacy(mode.prompt) {
                    d.name = mode.name
                    d.processingLabel = mode.processingLabel
                    d.prompt = mode.prompt
                }
                return d
            }
            if mode.id == ProcessingMode.macActionId {
                var d = ProcessingMode.macAction
                d.hotkeyBindings = mode.hotkeyBindings
                d.manualInputHotkey = mode.manualInputHotkey
                d.punctuationMode = mode.punctuationMode
                return d
            }
            if mode.id == ProcessingMode.translationModeId {
                var canonical = ProcessingMode.translation()
                canonical.hotkeyBindings = mode.hotkeyBindings
                canonical.manualInputHotkey = mode.manualInputHotkey
                canonical.punctuationMode = mode.punctuationMode
                let storedCode = mode.translationTargetLanguageCode?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                canonical.translationTargetLanguageCode =
                    storedCode.flatMap { $0.isEmpty ? nil : $0 }
                    ?? TranslationLanguage.english.rawValue
                return canonical
            }
            if mode.id == ProcessingMode.promptOptimize.id {
                // Detect any previous version by unique substrings
                let isLegacy = mode.prompt.contains("将口语化原始Prompt改写为结构清晰")  // V0 original
                    || (mode.prompt.contains("不编造具体方向") && !mode.prompt.contains("分析/研究/方案类任务"))  // V3 without complexity fix
                if isLegacy {
                    var migrated = ProcessingMode.promptOptimize
                    migrated.hotkeyBindings = mode.hotkeyBindings
                    migrated.manualInputHotkey = mode.manualInputHotkey
                    migrated.description = mode.description
                    migrated.punctuationMode = mode.punctuationMode
                    return migrated
                }
                return mode
            }
            // Drop legacy dual-channel mode (replaced by global "enhanced ASR" toggle)
            if mode.id == UUID(uuidString: "00000000-0000-0000-0000-000000000007")! {
                return nil
            }
            if mode.isBuiltin {
                return nil
            }
            return mode
        }

        // Ensure required built-in modes always exist.
        // direct + formalWriting (the original two) are inserted at their canonical positions
        // for existing users who already have them; any newly-added builtin is appended at the
        // end so it doesn't shove itself between the user's customized modes.
        let resultIds = Set(result.map { $0.id })
        let originalBuiltinIds: Set<UUID> = [
            ProcessingMode.directId,
            ProcessingMode.formalWritingId,
        ]
        var insertedRequiredBuiltin = false
        for builtin in ProcessingMode.builtins where !resultIds.contains(builtin.id) {
            var builtin = builtin
            if builtin.id == ProcessingMode.translationModeId {
                let selectedID = userDefaults.string(forKey: ModeSelectionPreference.storageKey)
                    .flatMap(UUID.init(uuidString:))
                let target: TranslationLanguage = selectedID == ProcessingMode.translateToChineseId
                    ? .simplifiedChinese
                    : .english
                builtin = ProcessingMode.translation(target: target)
            }
            if originalBuiltinIds.contains(builtin.id),
               let idx = ProcessingMode.builtins.firstIndex(where: { $0.id == builtin.id }) {
                let insertAt = min(idx, result.count)
                result.insert(builtin, at: insertAt)
            } else {
                result.append(builtin)
            }
            insertedRequiredBuiltin = true
        }
        if insertedRequiredBuiltin {
            try? save(result)
        }

        // One-time seeds for deletable default modes on existing installs.
        // Once seeded, deleting one is respected and will not re-inject it.
        let seededDefaults: [(mode: ProcessingMode, key: String)] = [
            (.agentMode, "tf_agentModeSeeded"),
        ]
        var seededAnyMode = false
        for seed in seededDefaults where !userDefaults.bool(forKey: seed.key) {
            if !result.contains(where: { $0.id == seed.mode.id }) {
                result.append(seed.mode)
                seededAnyMode = true
            }
            userDefaults.set(true, forKey: seed.key)
        }
        if seededAnyMode {
            // Persist immediately so seeded modes survive even if the user
            // quits before triggering another save path.
            try? save(result)
        }

        // One-time migration: the short-text-skip threshold used to be a single
        // global UserDefaults value that only applied to 语音润色 (formal writing).
        // Move it onto that mode so the per-mode setting preserves existing behavior.
        let exemptionMigratedKey = "tf_shortTextExemptionMigrated"
        if !userDefaults.bool(forKey: exemptionMigratedKey) {
            let legacyGlobal = Int(userDefaults.string(forKey: "tf_shortTextExemption") ?? "0") ?? 0
            if legacyGlobal > 0,
               let idx = result.firstIndex(where: { $0.id == ProcessingMode.formalWritingId }),
               result[idx].shortTextExemption == 0 {
                result[idx].shortTextExemption = legacyGlobal
                try? save(result)
            }
            userDefaults.set(true, forKey: exemptionMigratedKey)
        }

        return result
    }

    private func migrateDefaultMode(_ mode: ProcessingMode, fallback: ProcessingMode) -> ProcessingMode {
        guard mode.isBuiltin || mode.prompt.isEmpty else { return mode }

        var migrated = fallback
        if !mode.name.isEmpty {
            migrated.name = mode.name
        }
        if !mode.processingLabel.isEmpty {
            migrated.processingLabel = mode.processingLabel
        }
        if !mode.description.isEmpty {
            migrated.description = mode.description
        }
        migrated.hotkeyBindings = mode.hotkeyBindings
        migrated.manualInputHotkey = mode.manualInputHotkey
        migrated.shortTextExemption = mode.shortTextExemption
        migrated.punctuationMode = mode.punctuationMode
        migrated.isBuiltin = false
        return migrated
    }

    private func selectionAskPromptIsLegacy(_ prompt: String) -> Bool {
        prompt.contains("固定询问：“这句话是什么意思？”")
            || prompt.contains("先直接解释选中文本的核心含义")
            || prompt.contains("请用中文回答，允许使用 Markdown")
            || (!prompt.contains("# 用户语音问题") && prompt.contains("# 选中文本"))
            || (prompt.contains("你是语音问答助手") && !prompt.contains("{conversation}"))
    }
}
