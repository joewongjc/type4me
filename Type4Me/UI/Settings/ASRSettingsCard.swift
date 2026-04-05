import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ASR Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct ASRSettingsCard: View, SettingsCardHelpers {

    @AppStorage(DoubaoIntegrationController.enabledKey) private var doubaoIntegrationEnabled = false
    @State private var selectedASRProvider: ASRProvider = .volcano
    @State private var asrCredentialValues: [String: String] = [:]
    @State private var savedASRValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var asrTestStatus: SettingsTestStatus = .idle
    @State private var isEditingASR = true
    @State private var hasStoredASR = false
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

    private var currentASRFields: [CredentialField] {
        ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
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
        let required = currentASRFields.filter { !$0.isOptional }
        let effective = effectiveASRValues
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
            ]
        case .deepgram:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://developers.deepgram.com/docs/models-languages-overview/")!),
                ("API Key", L("获取", "get"), URL(string: "https://developers.deepgram.com/docs/create-additional-api-keys")!),
            ]
        case .assemblyai:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://www.assemblyai.com/docs/getting-started/models")!),
                ("API Key", L("获取", "get"), URL(string: "https://www.assemblyai.com/docs/faq/how-to-get-your-api-key")!),
            ]
        case .elevenlabs:
            return [
                ("API Key", L("获取", "get"), URL(string: "https://elevenlabs.io/app/settings/api-keys")!),
            ]
        case .soniox:
            return [
                ("API Key", L("获取", "get"), URL(string: "https://console.soniox.com")!),
            ]
        case .bailian:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api")!),
                ("API Key", L("获取", "get"), URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key")!),
            ]
        default:
            return []
        }
    }

    @ViewBuilder
    private func providerMenuItem(_ provider: ASRProvider) -> some View {
        Button {
            selectedASRProvider = provider
        } label: {
            Text(provider.displayName)
        }
    }

    private var currentProviderNote: String? {
        switch selectedASRProvider {
        case .deepgram:
            return L("受接口限制，热词仅取前 30 个", "Due to API limits, only the first 30 hotwords are used")
        default:
            return nil
        }
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("语音识别引擎", "ASR Provider"), icon: "mic.fill") {
            doubaoIntegrationToggle
            SettingsDivider()
            if !doubaoIntegrationEnabled {
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

                HStack(spacing: 8) {
                    Spacer()
                    testButton(L("测试连接", "Test"), status: asrTestStatus) { testASRConnection() }
                        .disabled(!hasASRCredentials || !isASRProviderAvailable)
                    if isZeroCredentialProvider {
                        EmptyView()
                    } else if hasASRCredentials && !isEditingASR {
                        secondaryButton(L("修改", "Edit")) {
                            testTask?.cancel()
                            asrTestStatus = .idle
                            asrCredentialValues = [:]
                            editedFields = []
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
                .padding(.top, 12)

                if let hint = volcResourceHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentAmber)
                        .padding(.top, 4)
                }



            }
            } // end if !doubaoIntegrationEnabled
        }
        .task {
            loadASRCredentials()
            refreshModelStatus()
        }
        .onChange(of: doubaoIntegrationEnabled) { _, enabled in
            // Notify the app to start/stop the observer
            NotificationCenter.default.post(name: .doubaoIntegrationDidChange, object: enabled)
        }
    }

    // MARK: - DoubaoIme Integration

    private var doubaoIntegrationToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $doubaoIntegrationEnabled) {
                HStack(spacing: 6) {
                    Text(L("豆包输入法语音识别", "DoubaoIme Voice Input"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                }
            }
            .toggleStyle(.switch)
            .tint(TF.settingsAccentBlue)

            if doubaoIntegrationEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(
                        "使用豆包输入法的语音识别，Type4Me 自动执行 Snippet 替换和历史记录。按模式快捷键可预设 LLM 处理。",
                        "Uses DoubaoIme for voice recognition. Type4Me auto-applies snippet replacement and history. Press a mode hotkey to arm LLM processing."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .lineSpacing(2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Provider Picker

    private static let recommendedProviders: [ASRProvider] = [.volcano, .soniox]
    #if HAS_SHERPA_ONNX
    private static let localProviders: [ASRProvider] = [.apple, .sherpa]
    #else
    private static let localProviders: [ASRProvider] = [.apple]
    #endif

    private var asrProviderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("识别引擎", "Provider").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            HStack(spacing: 10) {
                let localSet = Set(Self.localProviders)
                let availableSet = Set(ASRProvider.allCases
                    .filter { localSet.contains($0) || (ASRProviderRegistry.entry(for: $0)?.isAvailable ?? false) })
                let recommended = Self.recommendedProviders.filter { availableSet.contains($0) }
                let local = Self.localProviders.filter { availableSet.contains($0) }
                let others = ASRProvider.allCases.filter { availableSet.contains($0) && !Self.recommendedProviders.contains($0) && !Self.localProviders.contains($0) }

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
                    HStack(spacing: 8) {
                        Text(selectedASRProvider.displayName)
                            .font(.system(size: 13))
                            .foregroundStyle(TF.settingsText)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(TF.settingsCardAlt)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
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
                    qwen3Running = false
                    serverRunning = false
                }
            }
            // Start both servers when user explicitly switches to local ASR
            if newProvider == .sherpa {
                sensevoiceEnabled = true
                qwen3FinalEnabled = true
                startServer()
            }
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        let fields = currentASRFields
        let rows = stride(from: 0, to: fields.count, by: 2).map { i in
            Array(fields[i..<min(i+2, fields.count)])
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { SettingsDivider() }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row) { field in
                        credentialFieldRow(field)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if row.count == 1 {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func credentialFieldRow(_ field: CredentialField) -> some View {
        if !field.options.isEmpty {
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
            let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
            settingsSecureField(field.label, text: binding, prompt: placeholder)
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

    private var asrSummaryRows: [(String, String)] {
        var rows: [(String, String)] = []
        for field in currentASRFields {
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
        VStack(alignment: .leading, spacing: 8) {
            if localModelAvailable {
                // SenseVoice row
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("SenseVoice")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                        Text("|")
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                        Text(L("基础识别模型，流式识别，支持实时展示", "Base model, streaming ASR, real-time display"))
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    Spacer()
                    if svToggling {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text(L("启动中", "Starting"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TF.settingsTextSecondary)
                        }
                    } else if serverRunning {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(TF.settingsAccentGreen)
                            Text(L("运行中", "Running"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TF.settingsAccentGreen)
                        }
                        Button(L("停止", "Stop")) { toggleSenseVoice(false) }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.borderedProminent)
                            .tint(TF.settingsAccentRed)
                            .controlSize(.small)
                    } else {
                        Button(L("启动", "Start")) { toggleSenseVoice(true) }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.borderedProminent)
                            .tint(TF.settingsAccentAmber)
                            .controlSize(.small)
                    }
                }

                // Qwen3-ASR row (Apple Silicon only)
                #if arch(arm64)
                if hasQwen3ASR {
                    SettingsDivider()
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Qwen3-ASR")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TF.settingsText)
                            Text("|")
                                .font(.system(size: 10))
                                .foregroundStyle(TF.settingsTextTertiary.opacity(0.5))
                            Text(L("精准校验，建议搭配 SenseVoice", "Verification, best with SenseVoice"))
                                .font(.system(size: 10))
                                .foregroundStyle(TF.settingsTextTertiary)
                        }
                        Spacer()
                        if qwen3Toggling {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text(L("启动中", "Starting"))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(TF.settingsTextSecondary)
                            }
                        } else if qwen3Running {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(TF.settingsAccentGreen)
                                Text(L("运行中", "Running"))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(TF.settingsAccentGreen)
                            }
                            Button(L("停止", "Stop")) { toggleQwen3(false) }
                                .font(.system(size: 11, weight: .medium))
                                .buttonStyle(.borderedProminent)
                                .tint(TF.settingsAccentRed)
                                .controlSize(.small)
                        } else {
                            Button(L("启动", "Start")) { toggleQwen3(true) }
                                .font(.system(size: 11, weight: .medium))
                                .buttonStyle(.borderedProminent)
                                .tint(TF.settingsAccentAmber)
                                .controlSize(.small)
                        }
                    }
                }
                #endif

                // Test button at bottom
                SettingsDivider()
                HStack {
                    Spacer()
                    testButton(L("测试连接", "Test"), status: asrTestStatus) { testLocalModel() }
                }
            } else {
                // Lite version: no model bundled
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
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/joewongjc/type4me/releases")!)
                    } label: {
                        HStack(spacing: 2) {
                            Text(L("前往下载完整版", "Download Full Version"))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(TF.settingsAccentBlue)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(.vertical, 8)
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
        // SenseVoice Python server removed; native sherpa-onnx handles SenseVoice now.
        sensevoiceEnabled = enabled
    }

    private func toggleQwen3(_ enabled: Bool) {
        qwen3FinalEnabled = enabled
        qwen3Toggling = true
        Task {
            let mgr = SenseVoiceServerManager.shared
            if enabled {
                do {
                    try await mgr.startQwen3()
                    qwen3Running = await mgr.qwen3Port != nil
                } catch {
                    NSLog("[ASRSettings] Qwen3 start failed: %@", String(describing: error))
                    qwen3FinalEnabled = false
                }
            } else {
                await mgr.stopQwen3()
                qwen3Running = false
            }
            qwen3Toggling = false
        }
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
    }

    private func saveASRCredentials() {
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
        } catch {
            asrTestStatus = .failed(L("保存失败", "Save failed"))
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
                      let client = ASRProviderRegistry.createClient(for: provider)
                else {
                    guard !Task.isCancelled else { return }
                    asrTestStatus = .failed(L("不支持", "Unsupported"))
                    return
                }
                try await client.connect(config: config, options: currentASRRequestOptions(enablePunc: false))
                await client.disconnect()
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
        asrTestStatus = .failed(L("连接失败，请检查 App ID 和 Access Token", "Connection failed, check App ID & Access Token"))
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
        if let volc = error as? VolcASRError, case .serverRejected(_, let message) = volc {
            return message ?? L("服务器拒绝连接", "Server rejected")
        }
        if let volc = error as? VolcProtocolError, case .serverError(let code, let message) = volc {
            let desc = message ?? L("服务器错误", "Server error")
            return code.map { "\(desc) (\($0))" } ?? desc
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return L("网络未连接", "No internet")
            case .timedOut: return L("连接超时", "Timed out")
            case .cannotFindHost, .cannotConnectToHost: return L("无法连接服务器", "Cannot reach server")
            default: return urlError.localizedDescription
            }
        }
        return L("连接失败", "Connection failed") + ": " + error.localizedDescription
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
