import SwiftUI

struct LLMProviderDetailView: View, SettingsCardHelpers {
    let provider: LLMProvider
    let isDefault: Bool
    let onSetAsDefault: (LLMProvider) -> Void

    @State private var llmCredentialValues: [String: String] = [:]
    @State private var customModeFields: Set<String> = []
    @State private var llmTestStatus: SettingsTestStatus = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var disableThinking = false
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
        LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
    }

    private var effectiveLLMValues: [String: String] {
        var result = llmCredentialValues
        let fields = currentLLMFields
        for field in fields where result[field.key] == nil && !field.defaultValue.isEmpty {
            result[field.key] = field.defaultValue
        }
        return result
    }

    private var hasLLMCredentials: Bool {
        if provider == .codexCLI || provider == .ollama {
            return true
        }
        let fields = currentLLMFields
        let required = fields.filter { !$0.isOptional }
        let effective = effectiveLLMValues
        return required.allSatisfy { field in
            !(effective[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
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
        return provider.modelOptions.first?.value ?? ""
    }

    private var selectedThinkingDisableField: ThinkingDisableField? {
        provider.thinkingDisableField(for: selectedLLMModel)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            configurationSection
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .onAppear {
            loadCredentials()
        }
        .onChange(of: provider) { _, newProvider in
            testTask?.cancel()
            llmTestStatus = .idle
            fetchedModelOptions = []
            loadCredentials()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            BrandIconView(llm: provider, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TF.settingsText)

                    if provider.isLocal {
                        Text(L("本地", "Local"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(TF.settingsCardAlt))
                    } else if provider == .codexCLI {
                        Text(L("本机运行时", "Local CLI"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsAccentBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(TF.settingsAccentBlue.opacity(0.1)))
                    } else {
                        Text(L("云端大模型", "Cloud LLM"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(TF.settingsCardAlt))
                    }
                }
            }

            Spacer()

            // Set as Default Button / Active Badge
            Button {
                if !isDefault {
                    onSetAsDefault(provider)
                }
            } label: {
                HStack(spacing: 5) {
                    if isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsAccentBlue)
                        Text(L("当前默认引擎", "Default Engine"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TF.settingsAccentBlue)
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextSecondary)
                        Text(L("设为默认", "Set as Default"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isDefault ? TF.settingsAccentBlue.opacity(0.12) : TF.settingsCardAlt)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isDefault ? TF.settingsAccentBlue.opacity(0.3) : Color.black.opacity(0.06), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroupCard(L("参数配置", "Parameters"), icon: "slider.horizontal.3") {
                if provider == .codexCLI {
                    codexRuntimeNotice
                    SettingsDivider()
                }

                dynamicCredentialFields
            }

            // Test Connection Bar outside the card
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Spacer()
                    testButton(
                        L("测试连接", "Test"),
                        status: llmTestStatus,
                        isEnabled: hasLLMCredentials
                    ) { testLLMConnection() }
                }
                testStatusMessage(status: llmTestStatus)
            }
            .padding(.top, 4)
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
        .padding(.vertical, 6)
    }

    // MARK: - Dynamic Credential Fields

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
            if provider != .codexCLI {
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
                    return val.isEmpty ? field.defaultValue : val
                },
                set: { newValue in
                    if newValue == CredentialField.customValue {
                        customModeFields.insert(field.key)
                        llmCredentialValues[field.key] = ""
                    } else {
                        customModeFields.remove(field.key)
                        llmCredentialValues[field.key] = newValue
                    }
                    autoSave()
                }
            )
            let customBinding = Binding<String>(
                get: { llmCredentialValues[field.key] ?? "" },
                set: {
                    llmCredentialValues[field.key] = $0
                    autoSave()
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
                            .frame(width: SettingsControlWidth.input, height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                    }
                }
            }
        } else if !field.options.isEmpty {
            let pickerBinding = Binding<String>(
                get: {
                    let val = llmCredentialValues[field.key] ?? ""
                    return val.isEmpty ? field.defaultValue : val
                },
                set: {
                    llmCredentialValues[field.key] = $0
                    autoSave()
                }
            )
            settingsPickerField(field.label, selection: pickerBinding, options: field.options)
        } else if field.isSecure {
            let binding = Binding<String>(
                get: { llmCredentialValues[field.key] ?? "" },
                set: {
                    llmCredentialValues[field.key] = $0
                    autoSave()
                }
            )
            settingsSecureField(field.label, text: binding, prompt: field.placeholder)
        } else {
            let binding = Binding<String>(
                get: {
                    let val = llmCredentialValues[field.key] ?? ""
                    return val.isEmpty ? field.defaultValue : val
                },
                set: {
                    llmCredentialValues[field.key] = $0
                    autoSave()
                }
            )
            settingsField(field.label, text: binding, prompt: field.placeholder)
        }
    }

    // MARK: - Thinking Mode Row

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
                LLMThinkingPreference.setDisabled(disableThinking, for: provider)
            }
        )
    }

    private var thinkingToggleDescription: String {
        if provider == .kimi,
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
        case nil where provider.needsReasoningSplit:
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

    // MARK: - Credential Loading & Auto-save

    private func loadCredentials() {
        disableThinking = LLMThinkingPreference.isDisabled(for: provider)
        if let values = KeychainService.loadLLMCredentials(for: provider) {
            llmCredentialValues = values
        } else {
            var defaults: [String: String] = [:]
            let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            for field in fields where !field.defaultValue.isEmpty {
                defaults[field.key] = field.defaultValue
            }
            llmCredentialValues = defaults
        }
        syncCustomModeFields()
    }

    private func syncCustomModeFields() {
        var custom: Set<String> = []
        for field in currentLLMFields where field.allowCustomInput && !field.options.isEmpty {
            let val = llmCredentialValues[field.key] ?? field.defaultValue
            if !val.isEmpty && !field.options.contains(where: { $0.value == val }) {
                custom.insert(field.key)
            }
        }
        customModeFields = custom
    }

    private func autoSave() {
        let values = effectiveLLMValues
        do {
            try KeychainService.saveLLMCredentials(for: provider, values: values)
        } catch {
            NSLog("[LLMProviderDetailView] Auto-save failed: %@", String(describing: error))
        }
    }

    // MARK: - Test Connection & Fetch Models

    private func testLLMConnection() {
        testTask?.cancel()
        llmTestStatus = .testing
        let testValues = effectiveLLMValues
        let currentProvider = provider

        testTask = Task {
            do {
                guard let configType = LLMProviderRegistry.configType(for: currentProvider),
                      let config = configType.init(credentials: testValues)
                else {
                    guard !Task.isCancelled else { return }
                    llmTestStatus = .failed(L("配置无效", "Invalid config"))
                    return
                }
                let llmConfig = config.toLLMConfig()
                let client = LLMClientFactory.make(for: currentProvider)
                let reply = try await client.process(text: "hi", prompt: "{text}", config: llmConfig)
                guard !Task.isCancelled else { return }
                llmTestStatus = .success
                NSLog("[LLMProviderDetailView] LLM test OK (%@): %d chars", currentProvider.rawValue, reply.count)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[LLMProviderDetailView] LLM test failed (%@): %@", currentProvider.rawValue, String(describing: error))
                llmTestStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchModels() {
        guard !isFetchingModels else { return }
        isFetchingModels = true
        let values = effectiveLLMValues
        let currentProvider = provider

        testTask = Task {
            defer { isFetchingModels = false }
            do {
                guard let configType = LLMProviderRegistry.configType(for: currentProvider),
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
                NSLog("[LLMProviderDetailView] Fetched %d models for %@", models.count, currentProvider.rawValue)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[LLMProviderDetailView] Model fetch failed (%@): %@", currentProvider.rawValue, String(describing: error))
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
