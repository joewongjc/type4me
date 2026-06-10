import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LLM Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct LLMSettingsCard: View, SettingsCardHelpers {

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
    @State private var disableThinking: Bool = UserDefaults.standard.object(forKey: "tf_disableThinking") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "tf_disableThinking")
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

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("LLM 文本处理", "LLM Settings"), icon: "gearshape.fill") {
            llmProviderPicker
            SettingsDivider()

            if hasLLMCredentials && !isEditingLLM {
                credentialSummaryCard(rows: llmSummaryRows)
            } else {
                dynamicCredentialFields
            }

            HStack(spacing: 8) {
                Spacer()
                testButton(L("测试连接", "Test"), status: llmTestStatus) { testLLMConnection() }
                    .disabled(!hasLLMCredentials)
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
            .padding(.top, 12)
        }
        .task {
            loadLLMCredentials()
        }
    }

    private var thinkingToggleAvailable: Bool {
        selectedLLMProvider.thinkingDisableField != nil
    }

    private var thinkingModeBinding: Binding<String> {
        Binding(
            get: {
                guard thinkingToggleAvailable else { return "unsupported" }
                return disableThinking ? "disabled" : "default"
            },
            set: { newValue in
                guard thinkingToggleAvailable else { return }
                disableThinking = newValue == "disabled"
                UserDefaults.standard.set(disableThinking, forKey: "tf_disableThinking")
            }
        )
    }

    private var thinkingModeOptions: [(value: String, label: String)] {
        if thinkingToggleAvailable {
            return [
                ("disabled", L("禁用思考", "Disable Thinking")),
                ("default", L("模型默认", "Model Default")),
            ]
        }
        if selectedLLMProvider.needsReasoningSplit {
            return [("unsupported", L("分离 reasoning", "Separate reasoning"))]
        }
        return [("unsupported", L("模型默认", "Model Default"))]
    }

    private var thinkingToggleDescription: String {
        switch selectedLLMProvider {
        case .doubao, .kimi, .deepseek:
            return L("发送 thinking: disabled", "Sends thinking: disabled")
        case .bailian:
            return L("发送 enable_thinking: false", "Sends enable_thinking: false")
        case .zhipu:
            return L("发送 reasoning_effort: none", "Sends reasoning_effort: none")
        case .ollama:
            return L("发送 think: false", "Sends think: false")
        case .minimaxCN, .minimaxIntl:
            return L("不支持关闭，已自动分离 reasoning 内容", "Cannot disable; reasoning is separated")
        default:
            return L("暂无可靠关闭参数，仅隐藏返回中的 <think>", "No reliable disable parameter; hides returned <think>")
        }
    }

    private var thinkingModeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("思考模式", "Thinking Mode").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("|")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                Text(thinkingToggleDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }
            settingsDropdown(selection: thinkingModeBinding, options: thinkingModeOptions)
                .disabled(!thinkingToggleAvailable)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Provider Picker

    private var llmProviderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("服务商", "Provider").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { selectedLLMProvider.rawValue },
                    set: { if let p = LLMProvider(rawValue: $0) { selectedLLMProvider = p } }
                ),
                options: LLMProvider.allCases.map { ($0.rawValue, $0.displayName) }
            )
        }
        .padding(.vertical, 6)
        .onChange(of: selectedLLMProvider) { _, newProvider in
            testTask?.cancel()
            llmTestStatus = .idle
            isEditingLLM = true
            fetchedModelOptions = []
            loadLLMCredentialsForProvider(newProvider)

            // Auto-save provider switch if target already has credentials
            if hasLLMCredentials {
                KeychainService.selectedLLMProvider = newProvider
            }
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        let rows = arrangedCredentialRows()
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { SettingsDivider() }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row) { item in
                        credentialItemRow(item)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if row.count == 1 {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func arrangedCredentialRows() -> [[LLMCredentialItem]] {
        let fields = currentLLMFields
        let modelField = fields.first { $0.key == "model" }
        let nonModelFields = fields.filter { $0.key != "model" }
        var rows: [[LLMCredentialItem]] = []

        let firstRow = nonModelFields.prefix(2).map { LLMCredentialItem.credential($0) }
        if !firstRow.isEmpty {
            rows.append(firstRow)
        }

        if let modelField {
            rows.append([.credential(modelField), .thinkingMode])
        } else {
            rows.append([.thinkingMode])
        }

        let remaining = Array(nonModelFields.dropFirst(2)).map { LLMCredentialItem.credential($0) }
        for index in stride(from: 0, to: remaining.count, by: 2) {
            rows.append(Array(remaining[index..<min(index + 2, remaining.count)]))
        }

        return rows
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    settingsPickerField(field.label, selection: pickerBinding, options: allOptions)
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
                        .help(L("从 API 获取模型列表", "Fetch models from API"))
                        .disabled(isFetchingModels || !hasLLMCredentials)
                        .padding(.top, 18)
                    }
                }
                if customModeFields.contains(field.key) {
                    settingsField("", text: customBinding, prompt: field.placeholder)
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

    private func saveLLMCredentials() {
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
        } catch {
            llmTestStatus = .failed(L("保存失败", "Save failed"))
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
                let client: any LLMClient = provider == .claude
                    ? ClaudeChatClient()
                    : DoubaoChatClient(provider: provider)
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
