import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ASR Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct ASRSettingsCard: View, SettingsCardHelpers {

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
    @State private var localModelAvailable: Bool = ModelManager.isSenseVoiceBundled
    @State private var serverRunning = false
    @State private var serverStarting = false

    private var currentASRFields: [CredentialField] {
        ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
    }

    /// Effective values: saved base + dirty edits overlaid (including clears).
    private var effectiveASRValues: [String: String] {
        var result = savedASRValues
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
            return [(L("查看", "View"), L("配置指南", "setup guide"), URL(string: "https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr")!)]
        case .deepgram:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://developers.deepgram.com/docs/models-languages-overview/")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://developers.deepgram.com/docs/create-additional-api-keys")!),
            ]
        case .assemblyai:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://www.assemblyai.com/docs/getting-started/models")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://www.assemblyai.com/docs/faq/how-to-get-your-api-key")!),
            ]
        case .soniox:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://soniox.com/docs/stt/models")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://console.soniox.com")!),
            ]
        case .bailian:
            return [
                (L("可用模型", "Models"), L("查看", "view"), URL(string: "https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api")!),
                (L("API Key", "API Key"), L("获取", "get"), URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key")!),
            ]
        default:
            return []
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
                        Link(link.label, destination: link.url)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .padding(.bottom, 4)
            }
            SettingsDivider()

            if selectedASRProvider.isLocal {
                localModelSection
            } else {
                if hasASRCredentials && !isEditingASR {
                    credentialSummaryCard(rows: asrSummaryRows)
                } else {
                    dynamicCredentialFields
                }

                HStack(spacing: 8) {
                    Spacer()
                    testButton(L("测试连接", "Test"), status: asrTestStatus) { testASRConnection() }
                        .disabled(!hasASRCredentials || !isASRProviderAvailable)
                    if hasASRCredentials && !isEditingASR {
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
        }
        .task {
            loadASRCredentials()
            refreshModelStatus()
        }
    }

    // MARK: - Provider Picker

    private var asrProviderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("识别引擎", "Provider").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            HStack(spacing: 10) {
                settingsDropdown(
                    selection: Binding(
                        get: { selectedASRProvider.rawValue },
                        set: { if let p = ASRProvider(rawValue: $0) { selectedASRProvider = p } }
                    ),
                    options: ASRProvider.allCases
                        .filter { $0.isLocal || (ASRProviderRegistry.entry(for: $0)?.isAvailable ?? false) }
                        .map { ($0.rawValue, $0.displayName) }
                )
                if selectedASRProvider.isLocal && localModelAvailable {
                    testButton(L("测试模型", "Test Model"), status: asrTestStatus) { testLocalModel() }
                }
            }
        }
        .padding(.vertical, 6)
        .onChange(of: selectedASRProvider) { oldProvider, newProvider in
            testTask?.cancel()
            asrTestStatus = .idle
            isEditingASR = true
            // Persist provider switch immediately (don't require a separate "save")
            KeychainService.selectedASRProvider = newProvider
            loadASRCredentialsForProvider(newProvider)
            refreshModelStatus()
            // Stop SenseVoice server when switching away from sherpa
            if oldProvider == .sherpa && newProvider != .sherpa {
                Task { await SenseVoiceServerManager.shared.stop() }
            }
            // Start SenseVoice server when switching to sherpa
            if newProvider == .sherpa {
                Task { try? await SenseVoiceServerManager.shared.start() }
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
        let binding = Binding<String>(
            get: { asrCredentialValues[field.key] ?? "" },
            set: {
                asrCredentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
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
        } else {
            let savedVal = savedASRValues[field.key] ?? ""
            let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
            settingsField(field.label, text: binding, prompt: placeholder)
        }
    }

    private var asrSummaryRows: [(String, String)] {
        var rows: [(String, String)] = []
        for field in currentASRFields {
            let val = asrCredentialValues[field.key] ?? ""
            guard !val.isEmpty else { continue }
            rows.append((field.label, maskedSecret(val)))
        }
        return rows
    }

    // MARK: - Local Model Section

    /// Detect which local ASR model is actually configured by checking server directories.
    private var isQwen3ASR: Bool {
        // Qwen3-ASR server exists (dev or bundled)
        let home = NSHomeDirectory()
        let devQwen3 = (home as NSString).appendingPathComponent("projects/type4me/qwen3-asr-server/server.py")
        if FileManager.default.fileExists(atPath: devQwen3) { return true }
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("qwen3-asr-server").path,
           FileManager.default.fileExists(atPath: bundled) { return true }
        return false
    }

    private var localASRModelName: String {
        isQwen3ASR ? "Qwen3-ASR (MLX)" : "SenseVoice (ONNX)"
    }

    private var localASRModelDescription: String {
        isQwen3ASR
            ? L("阿里 Qwen3 语音模型，Metal GPU 加速，支持中英",
                 "Alibaba Qwen3 ASR, Metal GPU accelerated, zh/en")
            : L("阿里开源语音模型，支持中英粤日韩，自动标点，流式识别",
                 "Alibaba open-source ASR, zh/en/yue/ja/ko, auto punctuation, streaming")
    }

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if localModelAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TF.settingsAccentGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localASRModelName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                        Text(localASRModelDescription)
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                }

                // Inline server status
                SettingsDivider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(serverRunning ? TF.settingsAccentGreen : TF.settingsAccentRed)
                        .frame(width: 8, height: 8)
                    Text(serverRunning
                        ? L("推理服务运行中", "Server running")
                        : L("推理服务未启动", "Server stopped"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                    Spacer()
                    if !serverRunning && !serverStarting {
                        Button(L("启动", "Start")) {
                            startServer()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.borderedProminent)
                        .tint(TF.settingsAccentAmber)
                        .controlSize(.small)
                    } else if serverStarting {
                        ProgressView().controlSize(.small)
                    }
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
                    Link(L("前往下载完整版", "Download Full Version"),
                         destination: URL(string: "https://github.com/joewongjc/type4me/releases")!)
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func refreshModelStatus() {
        localModelAvailable = ModelManager.isSenseVoiceBundled
        Task { serverRunning = await SenseVoiceServerManager.shared.isRunning }
    }

    private func startServer() {
        serverStarting = true
        Task {
            do {
                try await SenseVoiceServerManager.shared.start()
                serverRunning = true
            } catch {
                NSLog("[ASRSettings] Server start failed: %@", String(describing: error))
            }
            serverStarting = false
        }
    }

    private func testLocalModel() {
        testTask?.cancel()
        asrTestStatus = .testing
        testTask = Task {
            do {
                // Ensure server is running
                let running = await SenseVoiceServerManager.shared.isRunning
                if !running {
                    try await SenseVoiceServerManager.shared.start()
                }
                // Health check
                let healthy = await SenseVoiceServerManager.shared.isHealthy()
                guard !Task.isCancelled else { return }
                if healthy {
                    asrTestStatus = .success
                } else {
                    asrTestStatus = .failed(L("服务未就绪", "Server not ready"))
                }
            } catch {
                guard !Task.isCancelled else { return }
                asrTestStatus = .failed(error.localizedDescription)
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
            boostingTableID: biasSettings.boostingTableID
        )
    }
}
