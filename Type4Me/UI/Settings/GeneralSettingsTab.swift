import SwiftUI
import ServiceManagement
import AVFoundation
import ApplicationServices

// MARK: - Shared Types

enum SettingsTestStatus: Equatable {
    case idle, testing, success, failed(String)
}

// MARK: - Shared UI Helpers

fileprivate protocol SettingsCardHelpers {}

@MainActor
extension SettingsCardHelpers {

    func settingsGroupCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 10)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TF.settingsBg)
        )
    }

    func settingsField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .frame(width: 100, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    func settingsSecureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .frame(width: 100, alignment: .leading)
            SecureField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    func credentialSummaryCard(rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 13))
                        .foregroundStyle(TF.settingsText)
                    Spacer(minLength: 12)
                    Text(row.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .frame(minHeight: 40)
                .padding(.vertical, 6)

                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
    }

    func saveButton(action: @escaping () -> Void) -> some View {
        Button(L("保存", "Save"), action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsNavActive))
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.settingsTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
            )
    }

    @ViewBuilder
    func statusBadge(_ status: SettingsTestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .success:
            HStack(spacing: 4) {
                Circle().fill(TF.settingsAccentGreen).frame(width: 6, height: 6)
                Text(L("成功", "OK")).font(.system(size: 10)).foregroundStyle(TF.settingsAccentGreen)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Circle().fill(TF.settingsAccentRed).frame(width: 6, height: 6)
                Text(msg).font(.system(size: 10)).foregroundStyle(TF.settingsAccentRed)
            }
        }
    }

    func maskedSecret(_ value: String) -> String {
        guard !value.isEmpty else { return L("未设置", "Not set") }
        guard value.count > 8 else { return L("已保存", "Saved") }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)••••\(suffix)"
    }
}

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

    // Local model states
    @State private var selectedStreamingModel: ModelManager.StreamingModel = ModelManager.selectedStreamingModel
    @State private var modelDownloadStatus: [ModelManager.StreamingModel: Bool] = [:]
    @State private var downloadingModel: ModelManager.StreamingModel? = nil
    @State private var downloadProgress: Double = 0
    @State private var downloadTask: Task<Void, Error>? = nil
    @State private var confirmingDelete: ModelManager.StreamingModel? = nil

    private var allASRFields: [CredentialField] {
        ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
    }

    private var currentASRFields: [CredentialField] {
        visibleASRFields(for: selectedASRProvider, fields: allASRFields)
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
        let required = allASRFields.filter { !$0.isOptional }
        let effective = effectiveASRValues
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    private var isASRProviderAvailable: Bool {
        ASRProviderRegistry.entry(for: selectedASRProvider)?.isAvailable ?? false
    }

    private var asrCapabilitySummary: String {
        ASRProviderRegistry.supportedModesSummary(for: selectedASRProvider)
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("语音识别引擎", "Speech Recognition")) {
            Text(L("用于默认的语音识别能力", "Powers the default speech-to-text capability"))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 6)
            asrProviderPicker
            if isASRProviderAvailable {
                Text(asrCapabilitySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
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
                    statusBadge(asrTestStatus)
                    Button(L("测试连接", "Test")) { testASRConnection() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
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
                        saveButton { saveASRCredentials() }
                            .disabled(!hasASRCredentials)
                    }
                }
                .padding(.top, 10)
            }
        }
        .task {
            loadASRCredentials()
            refreshModelStatus()
        }
    }

    // MARK: - Provider Picker

    private var asrProviderPicker: some View {
        HStack {
            Text(L("识别引擎", "ASR Engine"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .frame(width: 100, alignment: .leading)
            Picker("", selection: $selectedASRProvider) {
                ForEach(ASRProvider.allCases.filter {
                    $0.isLocal || (ASRProviderRegistry.entry(for: $0)?.isAvailable ?? false)
                }, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()

            if selectedASRProvider.isLocal && (modelDownloadStatus[selectedStreamingModel] ?? false) {
                Spacer()
                statusBadge(asrTestStatus)
                Button(L("测试模型", "Test Model")) { testLocalModel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .disabled(asrTestStatus == .testing)
            }
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
        .onChange(of: selectedASRProvider) { _, newProvider in
            testTask?.cancel()
            downloadTask?.cancel()
            downloadTask = nil
            downloadingModel = nil
            downloadProgress = 0
            asrTestStatus = .idle
            isEditingASR = true
            // Persist provider switch immediately (don't require a separate "save")
            KeychainService.selectedASRProvider = newProvider
            loadASRCredentialsForProvider(newProvider)
            refreshModelStatus()
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        VStack(spacing: 0) {
            ForEach(Array(currentASRFields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { SettingsDivider() }
                credentialFieldRow(field)
            }
        }
    }

    private func credentialFieldRow(_ field: CredentialField) -> some View {
        let binding = Binding<String>(
            get: { asrCredentialValues[field.key] ?? "" },
            set: {
                asrCredentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
        let savedVal = savedASRValues[field.key] ?? ""
        let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
        return settingsField(field.label, text: binding, prompt: placeholder)
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

    private var localModelSection: some View {
        VStack(spacing: 0) {
            if !isASRProviderAvailable {
                // SherpaOnnx framework not compiled — guide user
                localASRBuildGuide
            } else {
                ForEach(Array(ModelManager.StreamingModel.allCases.enumerated()), id: \.element) { index, model in
                    if index > 0 { SettingsDivider() }
                    modelRow(model)
                }
            }
        }
    }

    private func modelRow(_ model: ModelManager.StreamingModel) -> some View {
        let isDownloaded = modelDownloadStatus[model] ?? false
        let isSelected = selectedStreamingModel == model
        let isDownloading = downloadingModel == model

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if isDownloaded || isDownloading {
                    // Radio button — only for downloaded/downloading models
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                        .onTapGesture {
                            guard isDownloaded else { return }
                            selectedStreamingModel = model
                            ModelManager.selectedStreamingModel = model
                            asrTestStatus = .idle
                            let defaults = ["modelDir": ModelManager.defaultModelsDir]
                            try? KeychainService.saveASRCredentials(for: .sherpa, values: defaults)
                            KeychainService.selectedASRProvider = .sherpa
                        }
                } else {
                    // Not downloaded: download button on the left
                    Button(L("下载", "Download")) { startDownload(model) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(TF.settingsAccentAmber))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isDownloaded ? TF.settingsText : TF.settingsTextTertiary)
                        Text("~\(model.approximateSizeMB) MB")
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    Text(model.description)
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(2)
                }

                Spacer()

                // Action area (only for downloaded models)
                if isDownloaded {
                    HStack(spacing: 6) {
                        if confirmingDelete == model {
                            Button(L("确认删除", "Confirm")) { deleteModel(model) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(TF.settingsAccentRed))
                            Button(L("取消", "Cancel")) { confirmingDelete = nil }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TF.settingsTextSecondary)
                        } else {
                            Button {
                                confirmingDelete = model
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(TF.settingsTextTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Download progress
            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .tint(TF.settingsAccentAmber)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 30, alignment: .trailing)
                    Button(L("取消", "Cancel")) { cancelDownload() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 8)
    }

    private func refreshModelStatus() {
        for model in ModelManager.StreamingModel.allCases {
            modelDownloadStatus[model] = ModelManager.shared.isModelAvailable(model)
        }
        selectedStreamingModel = ModelManager.selectedStreamingModel
    }

    private func startDownload(_ model: ModelManager.StreamingModel) {
        // Cancel any existing download first
        if downloadingModel != nil {
            cancelDownload()
        }
        downloadingModel = model
        downloadProgress = 0
        asrTestStatus = .idle
        downloadTask = Task {
            do {
                try await ModelManager.shared.downloadModel(model) { progress in
                    Task { @MainActor in
                        // Only update if this model is still the one being downloaded
                        guard self.downloadingModel == model else { return }
                        self.downloadProgress = progress
                    }
                }
                await MainActor.run {
                    guard downloadingModel == model else { return }
                    downloadingModel = nil
                    refreshModelStatus()
                    // Auto-select if first download
                    if modelDownloadStatus.values.filter({ $0 }).count == 1 {
                        selectedStreamingModel = model
                        ModelManager.selectedStreamingModel = model
                        let defaults = ["modelDir": ModelManager.defaultModelsDir]
                        try? KeychainService.saveASRCredentials(for: .sherpa, values: defaults)
                        KeychainService.selectedASRProvider = .sherpa
                    }
                }
            } catch {
                await MainActor.run {
                    guard downloadingModel == model else { return }
                    downloadingModel = nil
                    if !Task.isCancelled {
                        asrTestStatus = .failed(L("下载失败", "Download failed"))
                    }
                }
            }
        }
    }

    private func cancelDownload() {
        guard let model = downloadingModel else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModel = nil
        Task { await ModelManager.shared.cancelDownload(model) }
    }

    private func deleteModel(_ model: ModelManager.StreamingModel) {
        Task {
            try? await ModelManager.shared.deleteModel(model)
            await MainActor.run {
                confirmingDelete = nil
                modelDownloadStatus[model] = false
                if selectedStreamingModel == model {
                    // Select another downloaded model, or keep current
                    if let alt = ModelManager.StreamingModel.allCases.first(where: {
                        modelDownloadStatus[$0] == true
                    }) {
                        selectedStreamingModel = alt
                        ModelManager.selectedStreamingModel = alt
                    }
                }
                asrTestStatus = .idle
            }
        }
    }

    private var localASRBuildGuide: some View {
        HStack(spacing: 4) {
            Text(L("本地暂未部署识别引擎，请查看", "Local ASR engine not deployed. See"))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
            Link(
                L("GitHub 详细指引", "GitHub instructions"),
                destination: URL(string: "https://github.com/joewongjc/type4me#方式二从源码构建")!
            )
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, 8)
    }

    private func testLocalModel() {
        testTask?.cancel()
        asrTestStatus = .testing
        testTask = Task {
            #if HAS_SHERPA_ONNX
            do {
                let config = SherpaASRConfig(credentials: ["modelDir": ModelManager.defaultModelsDir])
                guard let config else {
                    guard !Task.isCancelled else { return }
                    asrTestStatus = .failed(L("配置错误", "Config error"))
                    return
                }
                let client = SherpaASRClient()
                try await client.connect(config: config, options: currentASRRequestOptions(enablePunc: false))
                await client.disconnect()
                guard !Task.isCancelled else { return }
                asrTestStatus = .success
            } catch {
                guard !Task.isCancelled else { return }
                asrTestStatus = .failed(L("加载失败", "Load failed"))
            }
            #else
            asrTestStatus = .failed(L("SherpaOnnx 未编译", "SherpaOnnx not available"))
            #endif
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
        var defaults: [String: String] = [:]
        let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
        for field in fields where !field.defaultValue.isEmpty {
            defaults[field.key] = field.defaultValue
        }

        if let values = KeychainService.loadASRCredentials(for: provider) {
            let hydratedValues = defaults.merging(values) { _, new in new }
            asrCredentialValues = hydratedValues
            savedASRValues = hydratedValues
            hasStoredASR = true
            isEditingASR = !hasASRCredentials
        } else {
            asrCredentialValues = defaults
            savedASRValues = defaults
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
            asrTestStatus = .success
        } catch {
            asrTestStatus = .failed(L("保存失败", "Save failed"))
        }
    }

    private func testASRConnection() {
        testTask?.cancel()
        asrTestStatus = .testing
        let testValues = effectiveASRValues
        let provider = selectedASRProvider
        testTask = Task {
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
                asrTestStatus = .failed(L("连接失败", "Connection failed"))
            }
        }
    }

    private func currentASRRequestOptions(enablePunc: Bool) -> ASRRequestOptions {
        let biasSettings = ASRBiasSettingsStorage.load()
        return ASRRequestOptions(
            enablePunc: enablePunc,
            hotwords: HotwordStorage.load(),
            boostingTableID: biasSettings.boostingTableID
        )
    }

    private func visibleASRFields(for provider: ASRProvider, fields: [CredentialField]) -> [CredentialField] {
        guard provider == .baidu else { return fields }
        return fields.filter { !["devPID", "cuid", "lmId"].contains($0.key) }
    }
}

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

    private var currentLLMFields: [CredentialField] {
        LLMProviderRegistry.configType(for: selectedLLMProvider)?.credentialFields ?? []
    }

    /// Effective values: saved base + dirty edits overlaid.
    private var effectiveLLMValues: [String: String] {
        var result = savedLLMValues
        for key in editedFields {
            result[key] = llmCredentialValues[key] ?? ""
        }
        return result
    }

    private var hasLLMCredentials: Bool {
        let required = currentLLMFields.filter { !$0.isOptional }
        let effective = effectiveLLMValues
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(L("LLM 文本处理", "LLM Text Processing")) {
            Text(L("用于自定义模式对输出的文本进行二次处理", "Post-processes transcribed text in custom modes"))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 6)
            llmProviderPicker
            SettingsDivider()

            if hasLLMCredentials && !isEditingLLM {
                credentialSummaryCard(rows: llmSummaryRows)
            } else {
                dynamicCredentialFields
            }

            Text(L("纠错、翻译、Prompt 优化等场景均通过此接口完成。", "Handles correction, translation, prompt optimization and more."))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Spacer()
                statusBadge(llmTestStatus)
                Button(L("测试连接", "Test")) { testLLMConnection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .disabled(!hasLLMCredentials)
                if hasLLMCredentials && !isEditingLLM {
                    secondaryButton(L("修改", "Edit")) {
                        testTask?.cancel()
                        llmTestStatus = .idle
                        llmCredentialValues = [:]
                        editedFields = []
                        isEditingLLM = true
                    }
                } else {
                    if hasLLMCredentials && hasStoredLLM {
                        secondaryButton(L("取消", "Cancel")) {
                            testTask?.cancel()
                            llmTestStatus = .idle
                            loadLLMCredentials()
                        }
                    }
                    saveButton { saveLLMCredentials() }
                        .disabled(!hasLLMCredentials)
                }
            }
            .padding(.top, 10)
        }
        .task {
            loadLLMCredentials()
        }
    }

    // MARK: - Provider Picker

    private var llmProviderPicker: some View {
        HStack {
            Text(L("服务商", "Provider"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .frame(width: 100, alignment: .leading)
            Picker("", selection: $selectedLLMProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
        .onChange(of: selectedLLMProvider) { _, newProvider in
            testTask?.cancel()
            llmTestStatus = .idle
            isEditingLLM = true
            loadLLMCredentialsForProvider(newProvider)
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        VStack(spacing: 0) {
            ForEach(Array(currentLLMFields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { SettingsDivider() }
                credentialFieldRow(field)
            }
        }
    }

    private func credentialFieldRow(_ field: CredentialField) -> some View {
        let binding = Binding<String>(
            get: { llmCredentialValues[field.key] ?? "" },
            set: {
                llmCredentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
        let savedVal = savedLLMValues[field.key] ?? ""
        let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
        if field.isSecure {
            return AnyView(settingsSecureField(field.label, text: binding, prompt: placeholder))
        } else {
            return AnyView(settingsField(field.label, text: binding, prompt: placeholder))
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
            llmTestStatus = .success
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
                NSLog("[Settings] LLM test OK (%@): %@", provider.rawValue, reply)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[Settings] LLM test failed (%@): %@", provider.rawValue, String(describing: error))
                llmTestStatus = .failed(L("连接失败", "Connection failed"))
            }
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - General Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct GeneralSettingsTab: View, SettingsCardHelpers {

    // MARK: - Global

    @AppStorage("tf_startSound") private var startSound = StartSoundStyle.chime.rawValue
    @AppStorage("tf_launchAtLogin") private var launchAtLogin = true
    @AppStorage("tf_lowerVolumeOnRecord") private var lowerVolumeOnRecord = false
    @AppStorage("tf_visualStyle") private var visualStyle = "timeline"
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    @State private var hasMic = false
    @State private var hasAccessibility = false

    typealias TestStatus = SettingsTestStatus

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "GENERAL",
                title: L("通用设置", "General Settings"),
                description: L("接口配置与偏好设置。快捷键请在「处理模式」中配置。", "API configuration and preferences. Hotkeys are configured in Modes.")
            )

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MODULE 1: 全局设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            moduleHeader(L("全局设置", "Global"))

            twoColumnLayout {
                settingsGroupCard(L("偏好", "Preferences")) {
                    startSoundRow
                    SettingsDivider()
                    settingsToggleRow(L("开机自动启动", "Launch at login"), isOn: $launchAtLogin)
                    SettingsDivider()
                    settingsToggleRow(L("录音时降低系统音量", "Lower volume while recording"), isOn: $lowerVolumeOnRecord)
                    SettingsDivider()
                    visualStyleRow
                    SettingsDivider()
                    languageRow
                }
            } right: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L("系统权限", "Permissions"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TF.settingsTextTertiary)
                        Spacer()
                        Button { checkPermissions() } label: {
                            Label(L("刷新", "Refresh"), systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TF.settingsTextSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 10)

                    HStack(spacing: 8) {
                        permissionBlock(
                            icon: "mic.fill", name: L("麦克风", "Microphone"), granted: hasMic
                        ) {
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                Task { @MainActor in hasMic = granted }
                            }
                        }

                        permissionBlock(
                            icon: "accessibility", name: L("辅助功能", "Accessibility"), granted: hasAccessibility
                        ) {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(TF.settingsBg)
                )
            }

            moduleSpacer()

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MODULE 2: API 设置
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            moduleHeader(L("API 设置", "API Settings"))

            twoColumnLayout {
                ASRSettingsCard()
            } right: {
                LLMSettingsCard()
            }

        }
        .task {
            checkPermissions()
            syncLoginItemState()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            setLoginItem(enabled: newValue)
        }
    }

    // MARK: - Layout Helpers

    private func moduleHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(TF.settingsText)
                .padding(.bottom, 12)
        }
    }

    private func moduleSpacer() -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)
            Divider()
            Spacer().frame(height: 20)
        }
    }

    private func twoColumnLayout<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                left()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                right()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 16) {
                left()
                right()
            }
        }
    }

    // MARK: - Row Builders

    private func settingsToggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    private var startSoundRow: some View {
        HStack {
            Text(L("提示音", "Start sound"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Picker("", selection: $startSound) {
                ForEach(StartSoundStyle.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: startSound) { _, newValue in
                if let style = StartSoundStyle(rawValue: newValue) {
                    SoundFeedback.previewStartSound(style)
                }
            }
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    private var visualStyleRow: some View {
        HStack {
            Text(L("录音动效", "Visual style"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Picker("", selection: $visualStyle) {
                Text(L("线条", "Lines")).tag("classic")
                Text(L("粒子云", "Particles")).tag("dual")
                Text(L("电平", "Level")).tag("timeline")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    private var languageRow: some View {
        HStack {
            Text(L("界面语言", "Language"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Picker("", selection: $language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .frame(minHeight: 40)
        .padding(.vertical, 6)
    }

    // MARK: - Permission Block

    private func permissionBlock(
        icon: String,
        name: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(granted ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                .frame(height: 28)

            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)

            if granted {
                HStack(spacing: 4) {
                    Circle().fill(TF.settingsAccentGreen).frame(width: 6, height: 6)
                    Text(L("已授权", "Granted"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
            } else {
                Button(L("授权", "Grant")) { action() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(TF.settingsAccentAmber))
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsCardAlt))
    }

    // MARK: - Permissions

    private func checkPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    // MARK: - Login Item

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }

    private func syncLoginItemState() {
        let status = SMAppService.mainApp.status
        if status == .notRegistered, !UserDefaults.standard.bool(forKey: "tf_didInitialLoginItemSetup") {
            // First launch: register login item by default
            UserDefaults.standard.set(true, forKey: "tf_didInitialLoginItemSetup")
            setLoginItem(enabled: true)
        } else {
            launchAtLogin = status == .enabled
        }
    }
}
