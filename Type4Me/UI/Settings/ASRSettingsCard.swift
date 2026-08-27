import SwiftUI

struct LocalASREngineSelection: Equatable {
    var senseVoiceEnabled: Bool
    var qwen3Enabled: Bool

    func settingSenseVoice(_ enabled: Bool, qwen3Available: Bool) -> Self {
        guard !enabled, !qwen3Enabled else {
            return Self(senseVoiceEnabled: enabled, qwen3Enabled: qwen3Enabled)
        }
        guard qwen3Available else { return self }
        return Self(senseVoiceEnabled: false, qwen3Enabled: true)
    }

    func settingQwen3(_ enabled: Bool) -> Self {
        Self(
            senseVoiceEnabled: enabled ? senseVoiceEnabled : true,
            qwen3Enabled: enabled
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ASR Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct ASRSettingsCard: View, SettingsCardHelpers {

    let draftCoordinator: SettingsDraftCoordinator

    @State private var selectedASRProvider: ASRProvider = .volcano
    @State private var asrCredentialValues: [String: String] = [:]
    @State private var savedASRValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var asrTestStatus: SettingsTestStatus = .idle
    @State private var isEditingASR = true
    @State private var hasStoredASR = false
    /// Tracks option fields currently using a free-form value instead of a preset.
    @State private var customASRModeFields: Set<String> = []
    @State private var testTask: Task<Void, Never>?
    /// Hint shown below ASR credentials when only bigasr works (not seed 2.0)
    @State private var volcResourceHint: String?

    // Local model states
    @State private var localModelAvailable: Bool = ModelManager.isQwen3ASRBundled
    @State private var serverRunning = false
    @State private var qwen3Running = false
    @State private var svToggling = false
    @State private var qwen3Toggling = false
    @AppStorage("tf_qwen3FinalEnabled") private var qwen3FinalEnabled = true
    @AppStorage("tf_sensevoiceEnabled") private var sensevoiceEnabled = true
    @State private var qwen3StartError: String?

    private var currentASRFields: [CredentialField] {
        ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
    }

    private var displayedASRFields: [CredentialField] {
        guard selectedASRProvider == .volcano else { return currentASRFields }
        let authMode = VolcanoASRConfig.inferredAuthMode(in: effectiveASRValues)
        return currentASRFields.filter { field in
            switch field.key {
            case "apiKey":
                return authMode == VolcanoASRConfig.authModeAPIKey
            case "appKey", "accessKey":
                return authMode == VolcanoASRConfig.authModeLegacy
            default:
                return true
            }
        }
    }

    private var isZeroCredentialProvider: Bool {
        currentASRFields.isEmpty && !selectedASRProvider.isLocal
    }

    /// Effective values: saved base + defaults for unsaved fields + dirty edits overlaid.
    private var effectiveASRValues: [String: String] {
        var result = savedASRValues
        // Fill in defaults for fields not yet saved (new provider scenario)
        for (key, value) in asrCredentialValues where result[key] == nil {
            result[key] = value
        }
        for key in editedFields {
            result[key] = asrCredentialValues[key] ?? ""
        }
        return result
    }

    private var hasASRCredentials: Bool {
        let effective = effectiveASRValues
        if selectedASRProvider == .volcano {
            return VolcanoASRConfig(credentials: effective) != nil
        }
        let required = currentASRFields.filter { !$0.isOptional }
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    private var isASRProviderAvailable: Bool {
        ASRProviderRegistry.entry(for: selectedASRProvider)?.isAvailable ?? false
    }

    private var currentASRGuideLinks: [(prefix: String?, label: String, url: URL)] {
        switch selectedASRProvider {
        case .volcano:
            return [
                (L("配置指南", "Setup guide"), L("查看", "view"), URL(string: "https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr")!),
                ("API Key", L("获取", "get"), URL(string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default")!),
                (L("官方文档", "Docs"), L("查看", "view"), URL(string: "https://www.volcengine.com/docs/6561/1354869?lang=zh")!),
            ]
        case .deepgram:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://developers.deepgram.com/docs/models-languages-overview/")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://developers.deepgram.com/docs/create-additional-api-keys")!),
            ]
        case .cartesia:
            return [
                (L("文档", "Docs"), L("查看", "view"), URL(string: "https://docs.cartesia.ai/use-the-api/stt/compare-endpoints")!),
                ("API Key", L("获取", "get"), URL(string: "https://play.cartesia.ai/keys")!),
            ]
        case .assemblyai:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://www.assemblyai.com/docs/getting-started/models")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://www.assemblyai.com/docs/faq/how-to-get-your-api-key")!),
            ]
        case .elevenlabs:
            return [
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://elevenlabs.io/app/settings/api-keys")!),
            ]
        case .gemini:
            return [
                (L("官方文档", "Docs"), L("查看", "view"), URL(string: "https://ai.google.dev/gemini-api/docs/live-api/live-transcribe")!),
                ("API Key", L("获取", "get"), URL(string: "https://aistudio.google.com/app/apikey")!),
                (L("定价与限制", "Pricing & Limits"), L("查看", "view"), URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!),
            ]
        case .grok:
            return [
                ("API Key", L("获取", "get"), URL(string: "https://console.x.ai/team/default/api-keys")!),
                (L("文档", "Docs"), L("查看", "view"), URL(string: "https://docs.x.ai/developers/model-capabilities/audio/speech-to-text")!),
            ]
        case .soniox:
            return [
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://console.soniox.com")!),
            ]
        case .bailian:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key")!),
            ]
        case .stepfunBatch:
            return [
                (L("接入文档", "Setup guide"), L("查看", "view"), URL(string: "https://platform.stepfun.com/docs/zh/api-reference/audio/asr-sse")!),
                ("API Key", L("获取", "get"), URL(string: "https://platform.stepfun.com/interface-key")!),
            ]
        case .mimo:
            return [
                (L("接入文档", "Setup guide"), L("查看", "view"), URL(string: "https://mimo.mi.com/docs/zh-CN/api/audio/Speech-Recognition")!),
                ("API Key", L("获取", "get"), URL(string: "https://platform.xiaomimimo.com")!),
            ]
        default:
            return []
        }
    }

    @ViewBuilder
    private func providerMenuItem(_ provider: ASRProvider) -> some View {
        let isBatch = !ASRProviderRegistry.capabilities(for: provider).supportsRealtimeRecognition
        Toggle(isOn: Binding(
            get: { provider == selectedASRProvider },
            set: { if $0 { selectedASRProvider = provider } }
        )) {
            if isBatch {
                Text("\(provider.displayName) (\(L("非实时", "Batch")))")
            } else {
                Text(provider.displayName)
            }
        }
    }

    private func asrProviderDropdownLabel(_ provider: ASRProvider) -> some View {
        let isBatch = !ASRProviderRegistry.capabilities(for: provider).supportsRealtimeRecognition
        return HStack(spacing: 8) {
            Text(provider.displayName)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if isBatch {
                Text(L("非实时", "Batch"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(TF.settingsCard)
                    )
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 88, minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TF.settingsCardAlt)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var currentProviderNote: String? {
        switch selectedASRProvider {
        case .volcano:
            return L(
                "新版控制台使用 API Key；旧版控制台继续使用 App ID + Access Token。选择 API Key 时优先走新版鉴权。",
                "Use an API Key with the new console, or App ID + Access Token with the legacy console. API Key mode uses the new authentication flow."
            )
        case .deepgram:
            return L("受接口限制，热词仅取前 30 个", "Due to API limits, only the first 30 hotwords are used")
        case .gemini:
            return L(
                "实时流式识别。Smart 模式会自动清理口语停顿、重复和自我纠正；如需逐字记录可切换为 Verbatim。",
                "Real-time streaming transcription. Smart mode cleans up disfluencies, repetitions, and self-corrections; switch to Verbatim for literal transcripts."
            )
        case .openai:
            return L(
                "松开快捷键后提交完整录音进行转写。",
                "The complete recording is submitted after you release the hotkey."
            )
        case .stepfunBatch:
            return L(
                "松开快捷键后提交完整录音；Step Plan 与标准按量付费需显式选择",
                "The complete recording is submitted after you release the hotkey; explicitly choose Step Plan or standard pay-as-you-go"
            )
        case .mimo:
            return L(
                "松开快捷键后提交完整录音；MiMo 的流式模式仅流式返回识别文本，不支持录音期间实时上传。",
                "The complete recording is submitted after you release the hotkey. MiMo streams transcript text only; it does not accept live audio chunks while recording."
            )
        default:
            return nil
        }
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("语音识别引擎", "ASR Provider"), icon: "mic.fill") {
            asrProviderPicker
            if !currentASRGuideLinks.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(currentASRGuideLinks.enumerated()), id: \.offset) { index, link in
                        if index > 0 {
                            Text("·").font(.system(size: 10)).foregroundStyle(TF.settingsTextTertiary)
                        }
                        if let prefix = link.prefix {
                            Text(prefix).font(.system(size: 10)).foregroundStyle(TF.settingsTextTertiary)
                        }
                        Button {
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            HStack(spacing: 2) {
                                Text(link.label)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 7))
                            }
                            .foregroundStyle(TF.settingsAccentBlue)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                    }
                }
                .padding(.bottom, 4)
            }
            if let note = currentProviderNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.bottom, 4)
            }
            SettingsDivider()

            if selectedASRProvider.isLocal {
                localModelSection
            } else {
                if isZeroCredentialProvider {
                    Text(L("此引擎无需 API 凭证，可直接测试和使用。", "This provider requires no API credentials and can be used directly."))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.vertical, 8)
                } else if hasASRCredentials && !isEditingASR {
                    credentialSummaryCard(rows: asrSummaryRows)
                } else {
                    dynamicCredentialFields
                }

                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        Spacer()
                        testButton(
                            L("测试连接", "Test"),
                            status: asrTestStatus,
                            isEnabled: hasASRCredentials && isASRProviderAvailable
                        ) { testASRConnection() }
                        if isZeroCredentialProvider {
                            EmptyView()
                        } else if hasASRCredentials && !isEditingASR {
                            secondaryButton(L("修改", "Edit")) {
                                testTask?.cancel()
                                asrTestStatus = .idle
                                asrCredentialValues = [:]
                                editedFields = []
                                syncCustomASRModeFields()
                                isEditingASR = true
                            }
                        } else {
                            if hasASRCredentials && hasStoredASR {
                                secondaryButton(L("取消", "Cancel")) {
                                    testTask?.cancel()
                                    asrTestStatus = .idle
                                    loadASRCredentials()
                                }
                            }
                            primaryButton(L("保存", "Save")) { saveASRCredentials() }
                                .disabled(!hasASRCredentials)
                        }
                    }
                    testStatusMessage(status: asrTestStatus)
                }
                .padding(.top, 12)

                if let hint = volcResourceHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentAmber)
                        .padding(.top, 4)
                }
            }
        }
        .task {
            loadASRCredentials()
            refreshModelStatus()
        }
        .onAppear {
            draftCoordinator.register(
                .asrCredentials,
                isDirty: { !editedFields.isEmpty },
                save: saveASRCredentials,
                discard: loadASRCredentials
            )
        }
        .onDisappear {
            draftCoordinator.unregister(.asrCredentials)
        }
    }

    // MARK: - Provider Picker

    private static let recommendedProviders: [ASRProvider] = [.volcano, .soniox]
    #if HAS_SHERPA_ONNX
    private static let localProviders: [ASRProvider] = ModelManager.isQwen3ASRBundled ? [.apple, .sherpa] : [.apple]
    #else
    private static let localProviders: [ASRProvider] = [.apple]
    #endif

    private var asrProviderPicker: some View {
        settingsOptionRow(
            L("识别引擎", "Provider"),
            controlWidth: SettingsControlWidth.provider
        ) {
                let localSet = Set(Self.localProviders)
                let availableSet = Set(ASRProvider.allCases
                    .filter { p in
                        guard localSet.contains(p) || (ASRProviderRegistry.entry(for: p)?.isAvailable ?? false) else { return false }
                        #if HAS_CLOUD_SUBSCRIPTION
                        if p == .cloud { return false }
                        #endif
                        return true
                    })
                let recommended = Self.recommendedProviders.filter { availableSet.contains($0) }
                let local = Self.localProviders.filter { availableSet.contains($0) }
                let others = ASRProvider.allCases
                    .filter { availableSet.contains($0) && !Self.recommendedProviders.contains($0) && !Self.localProviders.contains($0) }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

                Menu {
                    if !recommended.isEmpty {
                        Section(L("推荐", "Recommended")) {
                            ForEach(recommended, id: \.rawValue) { provider in
                                providerMenuItem(provider)
                            }
                        }
                    }
                    if !local.isEmpty {
                        Section(L("本地", "Local")) {
                            ForEach(local, id: \.rawValue) { provider in
                                providerMenuItem(provider)
                            }
                        }
                    }
                    if !others.isEmpty {
                        Section(L("其他", "Others")) {
                            ForEach(others, id: \.rawValue) { provider in
                                providerMenuItem(provider)
                            }
                        }
                    }
                } label: {
                    asrProviderDropdownLabel(selectedASRProvider)
                }
                .buttonStyle(.plain)
        }
        .onChange(of: selectedASRProvider) { oldProvider, newProvider in
            // Skip if this is the initial load (oldProvider is the @State default, not a real switch)
            guard oldProvider == KeychainService.selectedASRProvider || oldProvider == newProvider else {
                // Initial load: just sync credentials, don't start/stop servers
                loadASRCredentialsForProvider(newProvider)
                refreshModelStatus()
                return
            }

            testTask?.cancel()
            asrTestStatus = .idle
            isEditingASR = true
            KeychainService.selectedASRProvider = newProvider
            loadASRCredentialsForProvider(newProvider)
            refreshModelStatus()
            // Stop servers when switching away from local ASR
            if oldProvider == .sherpa && newProvider != .sherpa {
                Task {
                    await SenseVoiceServerManager.shared.stopQwen3()
                    #if HAS_SHERPA_ONNX
                    SenseVoiceASRClient.releaseCachedModels()
                    #endif
                    qwen3Running = false
                    serverRunning = false
                }
            }
            // Start local services when user explicitly switches to local ASR.
            // Preserve the user's SenseVoice preview preference; if both engines
            // were off, keep Qwen3 final enabled so local ASR still has an engine.
            if newProvider == .sherpa {
                if !sensevoiceEnabled && !qwen3FinalEnabled {
                    qwen3FinalEnabled = true
                }
                startServer()
            }
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        let fields = displayedASRFields
        return VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { SettingsDivider() }
                credentialFieldRow(field)
            }
        }
    }

    @ViewBuilder
    private func credentialFieldRow(_ field: CredentialField) -> some View {
        if !field.options.isEmpty && field.allowCustomInput {
            let allOptions = field.options + [
                FieldOption(
                    value: CredentialField.customValue,
                    label: selectedASRProvider == .deepgram
                        ? L("其他模型…", "Other model…")
                        : L("自定义…", "Custom…")
                )
            ]
            let pickerBinding = Binding<String>(
                get: {
                    if customASRModeFields.contains(field.key) {
                        return CredentialField.customValue
                    }
                    let val = asrCredentialValues[field.key] ?? ""
                    return val.isEmpty ? (savedASRValues[field.key] ?? field.defaultValue) : val
                },
                set: { newValue in
                    if newValue == CredentialField.customValue {
                        customASRModeFields.insert(field.key)
                        asrCredentialValues[field.key] = ""
                    } else {
                        customASRModeFields.remove(field.key)
                        asrCredentialValues[field.key] = newValue
                    }
                    editedFields.insert(field.key)
                }
            )
            let customBinding = Binding<String>(
                get: {
                    if let value = asrCredentialValues[field.key] {
                        return value
                    }
                    return savedASRValues[field.key] ?? ""
                },
                set: {
                    asrCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsOptionRow(field.label, controlWidth: SettingsControlWidth.input) {
                VStack(alignment: .trailing, spacing: 8) {
                    settingsDropdown(
                        selection: pickerBinding,
                        options: allOptions.map { ($0.value, $0.label) }
                    )
                    if customASRModeFields.contains(field.key) {
                        FixedWidthTextField(text: customBinding, placeholder: field.placeholder)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                        if field.key == "model", selectedASRProvider == .deepgram,
                           DeepgramASRConfig.isFluxModel(customBinding.wrappedValue) {
                            Label(
                                L("Flux 模型暂不支持；当前客户端使用 Deepgram V1 API。",
                                  "Flux models are not supported yet because this client uses the Deepgram V1 API."),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsAccentAmber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        } else if !field.options.isEmpty {
            let pickerBinding = Binding<String>(
                get: {
                    let val = asrCredentialValues[field.key] ?? ""
                    return val.isEmpty ? (savedASRValues[field.key] ?? field.defaultValue) : val
                },
                set: {
                    asrCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsPickerField(field.label, selection: pickerBinding, options: field.options)
        } else if field.isSecure {
            let binding = Binding<String>(
                get: { asrCredentialValues[field.key] ?? "" },
                set: {
                    asrCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            let savedVal = savedASRValues[field.key] ?? ""
            settingsSecureField(
                field.label,
                text: binding,
                prompt: secureFieldPlaceholder(field: field, savedValue: savedVal)
            )
        } else {
            let binding = Binding<String>(
                get: {
                    let val = asrCredentialValues[field.key] ?? ""
                    if val.isEmpty {
                        return savedASRValues[field.key] ?? field.defaultValue
                    }
                    return val
                },
                set: {
                    asrCredentialValues[field.key] = $0
                    editedFields.insert(field.key)
                }
            )
            settingsField(field.label, text: binding, prompt: field.placeholder)
        }
    }

    private var deepgramUsesOfficialEndpoint: Bool {
        let endpoint = effectiveASRValues["baseURL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return endpoint?.isEmpty == false ? endpoint == DeepgramASRConfig.defaultBaseURL : true
    }

    private func secureFieldPlaceholder(field: CredentialField, savedValue: String) -> String {
        if field.key == "apiKey", selectedASRProvider == .deepgram,
           !deepgramUsesOfficialEndpoint {
            return L("API 密钥或令牌", "API key or token")
        }
        return savedValue.isEmpty ? field.placeholder : maskedSecret(savedValue)
    }

    private var asrSummaryRows: [(String, String)] {
        var rows: [(String, String)] = []
        for field in displayedASRFields {
            let val = asrCredentialValues[field.key] ?? ""
            guard !val.isEmpty else { continue }
            let displayValue: String
            if field.isSecure {
                displayValue = maskedSecret(val)
            } else if let option = field.options.first(where: { $0.value == val }) {
                displayValue = option.label
            } else {
                displayValue = val
            }
            rows.append((field.label, displayValue))
        }
        return rows
    }

    // MARK: - Local Model Section

    /// Whether Qwen3-ASR server is available (dev or bundled).
    private var hasQwen3ASR: Bool {
        let home = NSHomeDirectory()
        let devQwen3 = (home as NSString).appendingPathComponent("projects/type4me/qwen3-asr-server/server.py")
        if FileManager.default.fileExists(atPath: devQwen3) { return true }
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("qwen3-asr-server").path,
           FileManager.default.fileExists(atPath: bundled) { return true }
        return false
    }

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if localModelAvailable {
                    localEngineRow(
                        name: "SenseVoice",
                        subtitle: L("流式识别引擎", "Streaming Engine"),
                        description: L("录音期间实时出字。关闭后仅使用 Qwen3-ASR 最终识别，可释放约 500MB 内存。",
                                       "Real-time preview while recording. Turn it off to use only Qwen3-ASR final transcription and free ~500MB."),
                        isOn: sensevoiceEnabled,
                        isToggling: false,
                        onToggle: toggleSenseVoice
                    )

                    #if arch(arm64)
                    if hasQwen3ASR {
                        SettingsDivider()
                        localEngineRow(
                            name: "Qwen3-ASR",
                            subtitle: L("精准识别引擎", "Precision Engine"),
                            description: L("识别完成后，对语音进行更准确的校准。内存占用约 4GB。",
                                           "Post-recognition calibration for higher accuracy. ~4GB memory."),
                            isOn: qwen3FinalEnabled,
                            isToggling: qwen3Toggling,
                            errorMessage: qwen3StartError,
                            onToggle: toggleQwen3
                        )
                    }
                    #endif

                HStack {
                    Spacer()
                    testButton(L("测试连接", "Test"), status: asrTestStatus) { testLocalModel() }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(TF.settingsAccentAmber)
                        Text(L("本地识别需要下载完整版", "Local ASR requires the full version"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                    }
                    Text(L("当前为云端识别版本，本地识别需要下载内嵌模型的完整版 DMG。",
                           "This is the cloud-only version. Download the full DMG with embedded model for local ASR."))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func localEngineRow(
        name: String,
        subtitle: String,
        description: String,
        isOn: Bool,
        isToggling: Bool,
        errorMessage: String? = nil,
        onToggle: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsOptionRow(
                name,
                subtitle: "\(subtitle) · \(description)",
                controlWidth: isToggling ? 110 : SettingsControlWidth.toggle
            ) {
                if isToggling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(isOn ? L("启动中", "Starting") : L("停止中", "Stopping"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                } else {
                    Toggle("", isOn: Binding(
                        get: { isOn },
                        set: onToggle
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.black)
                }
            }

            if let errorMessage, !isToggling, !isOn {
                Text(errorMessage)
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsAccentRed)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(.bottom, 8)
            }
        }
    }

    private func refreshModelStatus() {
        localModelAvailable = ModelManager.isQwen3ASRBundled
        Task {
            let mgr = SenseVoiceServerManager.shared
            serverRunning = await mgr.isRunning
            qwen3Running = await mgr.qwen3Port != nil
        }
    }

    private func startServer() {
        // Called by start() flow or provider switch - starts both if enabled
        svToggling = true
        qwen3Toggling = hasQwen3ASR && qwen3FinalEnabled
        Task {
            let mgr = SenseVoiceServerManager.shared
            do {
                try await mgr.start()
                serverRunning = await mgr.isRunning
                qwen3Running = await mgr.qwen3Port != nil
            } catch {
                NSLog("[ASRSettings] Server start failed: %@", String(describing: error))
            }
            svToggling = false
            qwen3Toggling = false
        }
    }

    private func toggleSenseVoice(_ enabled: Bool) {
        let selection = LocalASREngineSelection(
            senseVoiceEnabled: sensevoiceEnabled,
            qwen3Enabled: qwen3FinalEnabled
        ).settingSenseVoice(enabled, qwen3Available: hasQwen3ASR)
        guard selection.senseVoiceEnabled == enabled else { return }
        if selection.qwen3Enabled && !qwen3FinalEnabled {
            toggleQwen3(true)
        }
        sensevoiceEnabled = selection.senseVoiceEnabled
        serverRunning = enabled || qwen3Running
        if !enabled {
            #if HAS_SHERPA_ONNX
            SenseVoiceASRClient.releaseCachedModels()
            #endif
        }
    }

    private func toggleQwen3(_ enabled: Bool) {
        let selection = LocalASREngineSelection(
            senseVoiceEnabled: sensevoiceEnabled,
            qwen3Enabled: qwen3FinalEnabled
        ).settingQwen3(enabled)
        if selection.senseVoiceEnabled != sensevoiceEnabled {
            sensevoiceEnabled = selection.senseVoiceEnabled
            serverRunning = true
        }
        qwen3FinalEnabled = selection.qwen3Enabled
        qwen3Toggling = true
        qwen3StartError = nil
        Task {
            let mgr = SenseVoiceServerManager.shared
            if enabled {
                do {
                    try await mgr.startQwen3()
                    qwen3Running = await mgr.qwen3Port != nil
                } catch {
                    NSLog("[ASRSettings] Qwen3 start failed: %@", String(describing: error))
                    qwen3FinalEnabled = false
                    if !sensevoiceEnabled {
                        sensevoiceEnabled = true
                    }
                    qwen3StartError = extractStartError(error)
                }
            } else {
                await mgr.stopQwen3()
                qwen3Running = false
            }
            qwen3Toggling = false
        }
    }

    /// Pull a user-readable message from the server start error, including
    /// stderr output captured by DebugFileLogger when available.
    private func extractStartError(_ error: Error) -> String {
        let desc = String(describing: error)
        // Check recent debug log for the actual Python traceback
        let recent = DebugFileLogger.recentLines(10)
        if let metalLine = recent.first(where: { $0.contains("metallib") || $0.contains("ImportError") || $0.contains("Metal") }) {
            return metalLine
                .replacingOccurrences(of: "qwen3-asr-server: ", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        if desc.contains("portDiscovery") {
            return L("服务启动超时，请查看 Debug 日志", "Server start timed out. Check Debug logs.")
        }
        if desc.contains("Health check") {
            return L("服务启动后健康检查失败", "Health check failed after server start.")
        }
        return L("启动失败: ", "Start failed: ") + desc.prefix(120)
    }

    private func testLocalModel() {
        testTask?.cancel()
        asrTestStatus = .testing
        testTask = Task {
            let mgr = SenseVoiceServerManager.shared
            guard !Task.isCancelled else { return }

            let qwen3Healthy = await mgr.isHealthy()
            guard !Task.isCancelled else { return }

            if qwen3Healthy {
                asrTestStatus = .success
            } else {
                let q3Port = SenseVoiceServerManager.currentQwen3Port
                if q3Port == nil {
                    asrTestStatus = .failed(L("服务未启动", "No server running"))
                } else {
                    asrTestStatus = .failed(L("服务未就绪，请稍候重试", "Server not ready, try again"))
                }
            }
        }
    }

    // MARK: - Data

    private func loadASRCredentials() {
        selectedASRProvider = KeychainService.selectedASRProvider
        loadASRCredentialsForProvider(selectedASRProvider)
    }

    private func loadASRCredentialsForProvider(_ provider: ASRProvider) {
        testTask?.cancel()
        editedFields = []
        if let values = KeychainService.loadASRCredentials(for: provider) {
            asrCredentialValues = values
            savedASRValues = values
            hasStoredASR = true
            isEditingASR = !hasASRCredentials
        } else {
            var defaults: [String: String] = [:]
            let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
            for field in fields where !field.defaultValue.isEmpty {
                defaults[field.key] = field.defaultValue
            }
            asrCredentialValues = defaults
            savedASRValues = [:]
            hasStoredASR = false
            isEditingASR = true
        }
        syncCustomASRModeFields()
    }

    /// Shows the free-form field when a saved value is not one of the presets.
    private func syncCustomASRModeFields() {
        var custom: Set<String> = []
        let fields = ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
        for field in fields where field.allowCustomInput && !field.options.isEmpty {
            let val = asrCredentialValues[field.key]
                ?? savedASRValues[field.key]
                ?? field.defaultValue
            if !val.isEmpty && !field.options.contains(where: { $0.value == val }) {
                custom.insert(field.key)
            }
        }
        customASRModeFields = custom
    }

    @discardableResult
    private func saveASRCredentials() -> Bool {
        guard hasASRCredentials else {
            asrTestStatus = .failed(L("配置无效", "Invalid config"))
            return false
        }
        let values = effectiveASRValues
        do {
            try KeychainService.saveASRCredentials(for: selectedASRProvider, values: values)
            KeychainService.selectedASRProvider = selectedASRProvider
            asrCredentialValues = values
            savedASRValues = values
            editedFields = []
            hasStoredASR = true
            isEditingASR = false
            asrTestStatus = .saved
            return true
        } catch {
            asrTestStatus = .failed(L("保存失败", "Save failed"))
            return false
        }
    }

    private func testASRConnection() {
        testTask?.cancel()
        asrTestStatus = .testing
        volcResourceHint = nil
        let testValues = effectiveASRValues
        let provider = selectedASRProvider
        testTask = Task {
            // Volcengine: auto-detect when "auto" is selected
            if provider == .volcano && (testValues["resourceId"] ?? "") == VolcanoASRConfig.resourceIdAuto {
                await testVolcanoWithAutoResource(baseValues: testValues)
                return
            }
            do {
                guard let configType = ASRProviderRegistry.configType(for: provider),
                      let config = configType.init(credentials: testValues),
                      ASRProviderRegistry.entry(for: provider)?.isAvailable == true
                else {
                    guard !Task.isCancelled else { return }
                    asrTestStatus = .failed(L("不支持", "Unsupported"))
                    return
                }
                try await ASRProviderRegistry.validateCredentials(
                    for: provider,
                    config: config,
                    options: currentASRRequestOptions(enablePunc: false)
                )
                guard !Task.isCancelled else { return }
                asrTestStatus = .success
            } catch {
                guard !Task.isCancelled else { return }
                asrTestStatus = .failed(Self.describeConnectionError(error))
            }
        }
    }

    /// Test both Volcengine resource IDs and pick the best one.
    /// Saves with resourceId="auto" so the picker stays on "Auto", and stores the
    /// resolved ID in "resolvedResourceId" for actual connections.
    private func testVolcanoWithAutoResource(baseValues: [String: String]) async {
        let options = currentASRRequestOptions(enablePunc: false)
        let seedId = VolcanoASRConfig.resourceIdSeedASR
        let bigId = VolcanoASRConfig.resourceIdBigASR

        // Test Seed ASR 2.0 first (cheaper)
        let seedOK = await testVolcResource(baseValues: baseValues, resourceId: seedId, options: options)
        guard !Task.isCancelled else { return }

        if seedOK {
            var values = baseValues
            values["resourceId"] = VolcanoASRConfig.resourceIdAuto
            values["resolvedResourceId"] = seedId
            saveASRCredentialsQuietly(values)
            asrTestStatus = .success
            return
        }

        // Seed 2.0 failed, try bigasr
        let bigOK = await testVolcResource(baseValues: baseValues, resourceId: bigId, options: options)
        guard !Task.isCancelled else { return }

        if bigOK {
            var values = baseValues
            values["resourceId"] = VolcanoASRConfig.resourceIdAuto
            values["resolvedResourceId"] = bigId
            saveASRCredentialsQuietly(values)
            asrTestStatus = .success
            volcResourceHint = L(
                "当前使用大模型版本，开通「模型 2.0」可节省约 80% 费用，识别效果相同",
                "Using bigmodel tier. Enable \"Model 2.0\" for ~80% cost savings with identical quality"
            )
            return
        }

        // Both failed
        asrTestStatus = .failed(L("连接失败，请检查鉴权凭证", "Connection failed, check credentials"))
    }

    private func testVolcResource(baseValues: [String: String], resourceId: String, options: ASRRequestOptions) async -> Bool {
        var values = baseValues
        values["resourceId"] = resourceId
        guard let config = VolcanoASRConfig(credentials: values) else { return false }
        let client = VolcASRClient()
        do {
            try await client.connect(config: config, options: options)
            await client.disconnect()
            return true
        } catch {
            return false
        }
    }

    private func saveASRCredentialsQuietly(_ values: [String: String]) {
        do {
            try KeychainService.saveASRCredentials(for: .volcano, values: values)
            KeychainService.selectedASRProvider = .volcano
            asrCredentialValues = values
            savedASRValues = values
            editedFields = []
            hasStoredASR = true
            isEditingASR = false
        } catch {}
    }

    private static func describeConnectionError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        if let volc = error as? VolcASRError, case .serverRejected(_, let message) = volc {
            return message ?? L("服务器拒绝连接", "Server rejected")
        }
        if let volc = error as? VolcProtocolError, case .serverError(let code, let message) = volc {
            let desc = message ?? L("服务器错误", "Server error")
            return code.map { "\(desc) (\($0))" } ?? desc
        }
        if let urlError = error as? URLError {
            if let response = (urlError as NSError).userInfo["NSErrorFailingURLResponseKey"] as? HTTPURLResponse {
                return httpStatusMessage(statusCode: response.statusCode)
            }
            switch urlError.code {
            case .notConnectedToInternet: return L("网络未连接", "No internet")
            case .timedOut: return L("连接超时", "Timed out")
            case .cannotFindHost, .cannotConnectToHost: return L("无法连接服务器", "Cannot reach server")
            case .badServerResponse:
                return L("服务器响应异常，请检查鉴权凭证是否正确", "Bad server response — check your credentials")
            default: return urlError.localizedDescription
            }
        }
        return L("连接失败", "Connection failed") + ": " + error.localizedDescription
    }

    private static func httpStatusMessage(statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return L("鉴权凭证无效或已禁用", "Invalid or disabled credentials") + " (HTTP 401)"
        case 403:
            return L("鉴权凭证无权限访问该服务", "Credentials not authorized for this service") + " (HTTP 403)"
        case 429:
            return L("请求过于频繁", "Too many requests") + " (HTTP 429)"
        default:
            let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            return L("服务器拒绝连接", "Server rejected connection") + " (HTTP \(statusCode): \(reason))"
        }
    }

    private func currentASRRequestOptions(enablePunc: Bool) -> ASRRequestOptions {
        let biasSettings = ASRBiasSettingsStorage.load()
        return ASRRequestOptions(
            enablePunc: enablePunc,
            hotwords: HotwordStorage.load(),
            boostingTableID: biasSettings.boostingTableID,
            bypassProxy: ProxyBypassMode.current.bypassASR
        )
    }
}
