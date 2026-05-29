import Foundation

struct ModeStorage {

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Type4Me", isDirectory: true)
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
            if mode.id == ProcessingMode.directId {
                var d = ProcessingMode.direct
                d.hotkeyCode = mode.hotkeyCode
                d.hotkeyModifiers = mode.hotkeyModifiers
                d.hotkeyStyle = mode.hotkeyStyle
                return d
            }
            if mode.id == ProcessingMode.smartDirectId {
                return migrateDefaultMode(mode, fallback: .smartDirect)
            }
            if mode.id == ProcessingMode.translateId {
                return migrateDefaultMode(mode, fallback: .translate)
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
                d.hotkeyCode = mode.hotkeyCode
                d.hotkeyModifiers = mode.hotkeyModifiers
                d.hotkeyStyle = mode.hotkeyStyle
                // If user customized the prompt, keep theirs
                if !isLegacy {
                    d.name = mode.name
                    d.processingLabel = mode.processingLabel
                    d.prompt = mode.prompt
                }
                return d
            }
            if mode.id == ProcessingMode.translate.id {
                return migrateSeededDefaultPrompt(
                    mode,
                    legacyPrompts: [ProcessingMode.legacyTranslatePromptTemplate],
                    fallbackPrompt: ProcessingMode.translate.prompt
                )
            }
            if mode.id == ProcessingMode.promptOptimize.id {
                // Detect any previous version by unique substrings
                let isLegacy = mode.prompt.contains("将口语化原始Prompt改写为结构清晰")  // V0 original
                    || (mode.prompt.contains("不编造具体方向") && !mode.prompt.contains("分析/研究/方案类任务"))  // V3 without complexity fix
                if isLegacy {
                    var migrated = ProcessingMode.promptOptimize
                    migrated.hotkeyCode = mode.hotkeyCode
                    migrated.hotkeyModifiers = mode.hotkeyModifiers
                    migrated.hotkeyStyle = mode.hotkeyStyle
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
        for builtin in ProcessingMode.builtins where !resultIds.contains(builtin.id) {
            if originalBuiltinIds.contains(builtin.id),
               let idx = ProcessingMode.builtins.firstIndex(where: { $0.id == builtin.id }) {
                let insertAt = min(idx, result.count)
                result.insert(builtin, at: insertAt)
            } else {
                result.append(builtin)
            }
        }

        // One-time seed of agentMode for existing installs
        // (custom defaults are not auto-injected like builtins, so we seed once then respect the user's edits)
        let agentSeedKey = "tf_agentModeSeeded"
        if !UserDefaults.standard.bool(forKey: agentSeedKey) {
            if !result.contains(where: { $0.id == ProcessingMode.agentModeId }) {
                result.append(ProcessingMode.agentMode)
                // Persist immediately so the seeded mode survives even if the
                // user quits before triggering any save path.
                try? save(result)
            }
            UserDefaults.standard.set(true, forKey: agentSeedKey)
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
        migrated.hotkeyCode = mode.hotkeyCode
        migrated.hotkeyModifiers = mode.hotkeyModifiers
        migrated.hotkeyStyle = mode.hotkeyStyle
        migrated.isBuiltin = false
        return migrated
    }

    private func migrateSeededDefaultPrompt(
        _ mode: ProcessingMode,
        legacyPrompts: Set<String>,
        fallbackPrompt: String
    ) -> ProcessingMode {
        guard legacyPrompts.contains(mode.prompt) else { return mode }

        var migrated = mode
        migrated.prompt = fallbackPrompt
        migrated.isBuiltin = false
        return migrated
    }
}
