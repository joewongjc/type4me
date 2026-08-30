import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LLM Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct LLMSettingsCard: View, SettingsCardHelpers {

    let draftCoordinator: SettingsDraftCoordinator

    @State private var selectedLLMProvider: LLMProvider = .doubao
    @State private var llmCredentialValues: [String: String] = [:]
    @State private var savedLLMValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var llmTestStatus: SettingsTestStatus = .idle
    @State private var isEditingLLM = true
    @State private var hasStoredLLM = false
    @State private var testTask: Task<Void, Never>?
    /// Tracks which credential fields are in "custom input" mode (value not in preset options).
    @State private var customModeFields: Set<String> = []
    @State private var disableThinking = LLMThinkingPreference.isDisabled(for: .doubao)
    @State private var fetchedModelOptions: [FieldOption] = []
    @State private var isFetchingModels = false

    private enum LLMCredentialItem: Identifiable {
        case credential(CredentialField)
        case thinkingMode

        var id: String {
            switch self {
            case .credential(let field): return field.key
            case .thinkingMode: return "thinkingMode"
            }
        }
    }

    private var currentLLMFields: [CredentialField] {
        LLMProviderRegistry.configType(for: selectedLLMProvider)?.credentialFields ?? []
    }

    /// Effective values: saved base + dirty edits overlaid.
    private var effectiveLLMValues: [String: String] {
        LLMCredentialDraft.effectiveValues(
            fields: currentLLMFields,
            savedValues: savedLLMValues,
            draftValues: llmCredentialValues,
            editedFields: editedFields
        )
    }

    private var hasLLMCredentials: Bool {
        LLMCredentialDraft.hasRequiredValues(
            fields: currentLLMFields,
            values: effectiveLLMValues
        )
    }

    private var selectedLLMModel: String {
        if let model = effectiveLLMValues["model"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        if let modelField = currentLLMFields.first(where: { $0.key == "model" }),
           !modelField.defaultValue.isEmpty {
            return modelField.defaultValue
        }
        return selectedLLMProvider.modelOptions.first?.value ?? ""
    }

    private var selectedThinkingDisableField: ThinkingDisableField? {
        selectedLLMProvider.thinkingDisableField(for: selectedLLMModel)
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("LLM 文本处理", "LLM Settings"), icon: "gearshape.fill") {
            llmProviderPicker
            SettingsDivider()

            if selectedLLMProvider == .codexCLI {
                codexRuntimeNotice
                SettingsDivider()
            }

            if hasLLMCredentials && !isEditingLLM {
                credentialSummaryCard(rows: llmSummaryRows)
            } else {
                dynamicCredentialFields
            }

            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Spacer()
                    testButton(
                        L("测试连接", "Test"),
                        status: llmTestStatus,
                        isEnabled: hasLLMCredentials
                    ) { testLLMConnection() }
                    if hasLLMCredentials && !isEditingLLM {
                        secondaryButton(L("修改", "Edit")) {
                            testTask?.cancel()
                            llmTestStatus = .idle
                            llmCredentialValues = [:]
                            editedFields = []
                            isEditingLLM = true
                            syncCustomModeFields()
                        }
                    } else {
                        if hasLLMCredentials && hasStoredLLM {
                            secondaryButton(L("取消", "Cancel")) {
                                testTask?.cancel()
                                llmTestStatus = .idle
                                loadLLMCredentials()
                            }
                        }
                        primaryButton(L("保存", "Save")) { saveLLMCredentials() }
                            .disabled(!hasLLMCredentials)
                    }
                }
                testStatusMessage(status: llmTestStatus)
            }
            .padding(.top, 12)
        }
        .task {
            loadLLMCredentials()
        }
        .onAppear {
            draftCoordinator.register(
                .llmCredentials,
                isDirty: { !editedFields.isEmpty },
                save: saveLLMCredentials,
                discard: loadLLMCredentials
            )
        }
        .onDisappear {
            draftCoordinator.unregister(.llmCredentials)
        }
    }

    private var thinkingToggleAvailable: Bool {
        selectedThinkingDisableField != nil
    }

    private var thinkingModeBinding: Binding<Bool> {
        Binding(
            get: {
                thinkingToggleAvailable && disableThinking
            },
            set: { newValue in
                guard thinkingToggleAvailable else { return }
                disableThinking = newValue
                LLMThinkingPreference.setDisabled(disableThinking, for: selectedLLMProvider)
            }
        )
    }

    private var thinkingToggleDescription: String {
        if selectedLLMProvider == .kimi,
           selectedLLMModel.lowercased().hasPrefix("kimi-k2.7-code") {
            return L("K2.7 始终思考，不发送 thinking 参数", "K2.7 always thinks; no thinking parameter is sent")
        }

        switch selectedThinkingDisableField {
        case .thinking:
            return L("发送 thinking: disabled", "Sends thinking: disabled")
        case .enableThinking:
            return L("发送 enable_thinking: false", "Sends enable_thinking: false")
        case .reasoningEffort:
            return L("发送 reasoning_effort: none", "Sends reasoning_effort: none")
        case .reasoning:
            return L("发送 reasoning.effort: none", "Sends reasoning.effort: none")
        case .think:
            return L("发送 think: false", "Sends think: false")
        case nil where selectedLLMProvider.needsReasoningSplit:
            return L("不支持关闭，已自动分离 reasoning 内容", "Cannot disable; reasoning is separated")
        default:
            return L("暂无可靠关闭参数，仅隐藏返回中的 <think>", "No reliable disable parameter; hides returned <think>")
        }
    }

    private var thinkingModeRow: some View {
        settingsToggleRow(
            L("禁用思考", "Disable Thinking"),
            subtitle: thinkingToggleDescription,
            isOn: thinkingModeBinding,
            isEnabled: thinkingToggleAvailable
        )
    }

    // MARK: - Provider Picker

    private var llmProviderPicker: some View {
        settingsOptionRow(
            L("服务商", "Provider"),
            controlWidth: SettingsControlWidth.provider
        ) {
            settingsDropdown(
                selection: Binding(
                    get: { selectedLLMProvider.rawValue },
                    set: { if let p = LLMProvider(rawValue: $0) { selectedLLMProvider = p } }
                ),
                options: LLMProvider.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
        .onChange(of: selectedLLMProvider) { _, newProvider in
            testTask?.cancel()
            llmTestStatus = .idle
            isEditingLLM = true
            fetchedModelOptions = []
            loadLLMCredentialsForProvider(newProvider)

            // Auto-switch only when the target already has a saved config.
            // Defaults alone (notably Codex CLI's model) must not change the
            // active provider until the user explicitly saves.
            if hasStoredLLM && hasLLMCredentials {
                KeychainService.selectedLLMProvider = newProvider
            }
        }
    }

    private var codexRuntimeNotice: some View {
        Text(L(
            "使用本机已登录的 Codex CLI，无需单独配置 API Key。文本仍会发送到 OpenAI，并消耗 Codex 账号额度。",
            "Uses the Codex CLI already signed in on this Mac, with no separate API key configuration. Text is still sent to OpenAI and uses Codex account quota."
        ))
        .font(.system(size: 11))
        .foregroundStyle(TF.settingsTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        let items = arrangedCredentialItems()
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { SettingsDivider() }
                credentialItemRow(item)
            }
        }
    }

    private func arrangedCredentialItems() -> [LLMCredentialItem] {
        let fields = currentLLMFields
        let modelField = fields.first { $0.key == "model" }
        let nonModelFields = fields.filter { $0.key != "model" }
        var items: [LLMCredentialItem] = []

        items.append(contentsOf: nonModelFields.prefix(2).map { .credential($0) })

        if let modelField {
            items.append(.credential(modelField))
            if selectedLLMProvider != .codexCLI {
                items.append(.thinkingMode)
            }
        } else {
            items.append(.thinkingMode)
        }

        items.append(contentsOf: nonModelFields.dropFirst(2).map { .credential($0) })

        return items
    }

    @ViewBuilder
    private func credentialItemRow(_ item: LLMCredentialItem) -> some View {
        switch item {
        case .credential(let field):
            credentialFieldRow(field)
        case .thinkingMode:
            thinkingModeRow
        }
    }

    @ViewBuilder
    private func credentialFieldRow(_ field: CredentialField) -> some View {
        if !field.options.isEmpty && field.allowCustomInput {
            // Combobox: preset dropdown + "Custom" entry that reveals a text field.
            let mergedOptions = field.key == "model" && !fetchedModelOptions.isEmpty
                ? fetchedModelOptions
                : field.options
            let allOptions = mergedOptions + [FieldOption(value: CredentialField.customValue, label: L("自定义…", "Custom…"))]
            let pickerBinding = Binding<String>(
                get: {
                    if customModeFields.contains(field.key) {
                        return CredentialField.customValue
                    }
                    let val = llmCredentialValues[field.key] ?? ""
                    return val.isEmpty ? (savedLLMValues[field.key] ?? field.defaultValue) : val
                },
                set: { newValue in
                    if newValue == CredentialField.customValue {
                        customModeFields.insert(field.key)
                        llmCredentialValues[field.key] = ""
                        editedFields.insert(field.key)
                    } else {
                        customModeFields.remove(field.key)
                        llmCredentialValues[field.key] = newValue
                        editedFields.insert(field.key)
                    }
                }
            )
            let customBinding = Binding<String>(
                get: { llmCredentialValues[field.key] ?? "" },
                set: {
                    llmCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsOptionRow(field.label, controlWidth: SettingsControlWidth.input) {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        if field.key == "model" {
                            Button {
                                fetchModels()
                            } label: {
                                if isFetchingModels {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
                                }
                            }
                            .buttonStyle(.plain)
                            .settingsTooltip(L("从 API 获取模型列表", "Fetch models from API"))
                            .disabled(isFetchingModels || !hasLLMCredentials)
                        }
                        settingsDropdown(
                            selection: pickerBinding,
                            options: allOptions.map { ($0.value, $0.label) }
                        )
                    }
                    if customModeFields.contains(field.key) {
                        FixedWidthTextField(text: customBinding, placeholder: field.placeholder)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                    }
                }
            }
        } else if !field.options.isEmpty {
            let pickerBinding = Binding<String>(
                get: {
                    let val = llmCredentialValues[field.key] ?? ""
                    return val.isEmpty ? (savedLLMValues[field.key] ?? field.defaultValue) : val
                },
                set: {
                    llmCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsPickerField(field.label, selection: pickerBinding, options: field.options)
        } else if field.isSecure {
            let binding = Binding<String>(
                get: { llmCredentialValues[field.key] ?? "" },
                set: {
                    llmCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            let savedVal = savedLLMValues[field.key] ?? ""
            let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
            settingsSecureField(field.label, text: binding, prompt: placeholder)
        } else {
            // Non-secure text field: show saved/default value as actual text, not placeholder.
            let binding = Binding<String>(
                get: {
                    let val = llmCredentialValues[field.key] ?? ""
                    if val.isEmpty {
                        return savedLLMValues[field.key] ?? field.defaultValue
                    }
                    return val
                },
                set: {
                    llmCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsField(field.label, text: binding, prompt: field.placeholder)
        }
    }

    private var llmSummaryRows: [(String, String)] {
        var rows: [(String, String)] = []
        for field in currentLLMFields {
            let val = llmCredentialValues[field.key] ?? ""
            guard !val.isEmpty else { continue }
            let display = field.isSecure ? maskedSecret(val) : val
            rows.append((field.label, display))
        }
        return rows
    }

    // MARK: - Data

    /// Detects which combobox fields hold values not matching any preset option,
    /// and puts them into custom input mode so the UI shows the text field.
    private func syncCustomModeFields() {
        var custom: Set<String> = []
        for field in currentLLMFields where field.allowCustomInput && !field.options.isEmpty {
            let val = llmCredentialValues[field.key]
                ?? savedLLMValues[field.key]
                ?? field.defaultValue
            if !val.isEmpty && !field.options.contains(where: { $0.value == val }) {
                custom.insert(field.key)
            }
        }
        customModeFields = custom
    }

    private func loadLLMCredentials() {
        selectedLLMProvider = KeychainService.selectedLLMProvider
        loadLLMCredentialsForProvider(selectedLLMProvider)
    }

    private func loadLLMCredentialsForProvider(_ provider: LLMProvider) {
        testTask?.cancel()
        editedFields = []
        disableThinking = LLMThinkingPreference.isDisabled(for: provider)
        if let values = KeychainService.loadLLMCredentials(for: provider) {
            llmCredentialValues = values
            savedLLMValues = values
            hasStoredLLM = true
            isEditingLLM = !hasLLMCredentials
        } else {
            var defaults: [String: String] = [:]
            let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            for field in fields where !field.defaultValue.isEmpty {
                defaults[field.key] = field.defaultValue
            }
            llmCredentialValues = defaults
            savedLLMValues = [:]
            hasStoredLLM = false
            isEditingLLM = true
        }
        syncCustomModeFields()
    }

    @discardableResult
    private func saveLLMCredentials() -> Bool {
        guard hasLLMCredentials else {
            llmTestStatus = .failed(L("配置无效", "Invalid config"))
            return false
        }
        let values = effectiveLLMValues
        do {
            try KeychainService.saveLLMCredentials(for: selectedLLMProvider, values: values)
            KeychainService.selectedLLMProvider = selectedLLMProvider
            llmCredentialValues = values
            savedLLMValues = values
            editedFields = []
            hasStoredLLM = true
            isEditingLLM = false
            llmTestStatus = .saved
            return true
        } catch {
            llmTestStatus = .failed(L("保存失败", "Save failed"))
            return false
        }
    }

    private func testLLMConnection() {
        testTask?.cancel()
        llmTestStatus = .testing
        let testValues = effectiveLLMValues
        let provider = selectedLLMProvider
        testTask = Task {
            do {
                guard let configType = LLMProviderRegistry.configType(for: provider),
                      let config = configType.init(credentials: testValues)
                else {
                    guard !Task.isCancelled else { return }
                    llmTestStatus = .failed(L("配置无效", "Invalid config"))
                    return
                }
                let llmConfig = config.toLLMConfig()
                let client = LLMClientFactory.make(for: provider)
                let reply = try await client.process(text: "hi", prompt: "{text}", config: llmConfig)
                guard !Task.isCancelled else { return }
                llmTestStatus = .success
                NSLog("[Settings] LLM test OK (%@): %d chars", provider.rawValue, reply.count)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[Settings] LLM test failed (%@): %@", provider.rawValue, String(describing: error))
                llmTestStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchModels() {
        guard !isFetchingModels else { return }
        isFetchingModels = true
        let values = effectiveLLMValues
        let provider = selectedLLMProvider
        testTask = Task {
            defer { isFetchingModels = false }
            do {
                guard let configType = LLMProviderRegistry.configType(for: provider),
                      let config = configType.init(credentials: values)
                else { return }
                let llmConfig = config.toLLMConfig()
                guard let url = URL(string: "\(llmConfig.baseURL)/models") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("Bearer \(llmConfig.apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
                let models = decoded.data
                    .map { FieldOption(value: $0.id, label: $0.id) }
                    .sorted { $0.value < $1.value }
                guard !Task.isCancelled else { return }
                fetchedModelOptions = models
                NSLog("[Settings] Fetched %d models for %@", models.count, provider.rawValue)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[Settings] Model fetch failed (%@): %@", provider.rawValue, String(describing: error))
            }
        }
    }
}

// MARK: - /v1/models Response

private struct ModelsResponse: Decodable {
    let data: [ModelEntry]
}

private struct ModelEntry: Decodable {
    let id: String
}
