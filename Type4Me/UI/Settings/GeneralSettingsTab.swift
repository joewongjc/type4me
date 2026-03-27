import SwiftUI
import ServiceManagement
import AVFoundation
import ApplicationServices

// MARK: - Shared Types

enum SettingsTestStatus: Equatable {
    case idle, testing, saved, success, failed(String)

    var buttonForeground: Color {
        switch self {
        case .idle, .testing:  return TF.settingsText
        case .saved, .success: return TF.settingsAccentGreen
        case .failed:          return TF.settingsAccentRed
        }
    }

    var buttonBackground: Color {
        switch self {
        case .idle, .testing:  return TF.settingsCardAlt
        case .saved, .success: return TF.settingsAccentGreen.opacity(0.12)
        case .failed:          return TF.settingsAccentRed.opacity(0.12)
        }
    }
}

// MARK: - Shared UI Helpers

fileprivate protocol SettingsCardHelpers {}

@MainActor
extension SettingsCardHelpers {

    func settingsGroupCard<Content: View>(
        _ title: String,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentAmber)
                }
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.bottom, 14)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TF.settingsBg)
        )
    }

    func settingsField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            FixedWidthTextField(text: text, placeholder: prompt)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
        }
        .padding(.vertical, 6)
    }

    func settingsPickerField(_ label: String, selection: Binding<String>, options: [FieldOption]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: selection,
                options: options.map { ($0.value, $0.label) }
            )
        }
        .padding(.vertical, 6)
    }

    func settingsSecureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            FixedWidthSecureField(text: text, placeholder: prompt)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
        }
        .padding(.vertical, 6)
    }

    func credentialSummaryCard(rows: [(String, String)]) -> some View {
        let pairedRows = stride(from: 0, to: rows.count, by: 2).map { i in
            Array(rows[i..<min(i+2, rows.count)])
        }
        return VStack(spacing: 0) {
            ForEach(Array(pairedRows.enumerated()), id: \.offset) { index, pair in
                if index > 0 { SettingsDivider() }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(pair.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.0.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(TF.settingsTextTertiary)
                            HStack {
                                Text(item.1)
                                    .font(.system(size: 13))
                                    .foregroundStyle(TF.settingsTextSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(TF.settingsCardAlt)
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Custom Controls

    /// Custom dropdown that matches the design mockup (rounded rect + chevron).
    func settingsDropdown(selection: Binding<String>, options: [(value: String, label: String)], icon: String? = nil) -> some View {
        let currentLabel = options.first(where: { $0.value == selection.wrappedValue })?.label ?? selection.wrappedValue
        return Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection.wrappedValue = option.value
                } label: {
                    if option.value == selection.wrappedValue {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Text(currentLabel)
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

    /// Custom segmented picker with dark selected pill.
    func settingsSegmentedPicker(selection: Binding<String>, options: [(value: String, label: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection.wrappedValue == option.value
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection.wrappedValue = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : TF.settingsText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? TF.settingsNavActive : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TF.settingsCardAlt)
        )
    }

    func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsAccentAmber))
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
    }

    func saveButton(action: @escaping () -> Void) -> some View {
        primaryButton(L("保存", "Save"), action: action)
    }

    /// A "test connection" button that shows its own status inline.
    func testButton(_ title: String, status: SettingsTestStatus, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch status {
                case .idle:
                    Text(title)
                case .testing:
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(title)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text(L("已保存", "Saved"))
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text(L("连接成功", "Connected"))
                case .failed(let msg):
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text(msg)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.buttonForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(status.buttonBackground))
        }
        .buttonStyle(.plain)
        .disabled(status == .testing)
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
                if selectedASRProvider.isLocal && (modelDownloadStatus[selectedStreamingModel] ?? false) {
                    testButton(L("测试模型", "Test Model"), status: asrTestStatus) { testLocalModel() }
                }
            }
        }
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
                asrTestStatus = .failed(Self.describeConnectionError(error))
            }
        }
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
            loadLLMCredentialsForProvider(newProvider)
        }
    }

    // MARK: - Credential Fields

    private var dynamicCredentialFields: some View {
        let fields = currentLLMFields
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
            get: { llmCredentialValues[field.key] ?? "" },
            set: {
                llmCredentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
        if !field.options.isEmpty {
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
        } else {
            let savedVal = savedLLMValues[field.key] ?? ""
            let placeholder = savedVal.isEmpty ? field.placeholder : maskedSecret(savedVal)
            if field.isSecure {
                settingsSecureField(field.label, text: binding, prompt: placeholder)
            } else {
                settingsField(field.label, text: binding, prompt: placeholder)
            }
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
    @AppStorage("tf_volumeReduction") private var volumeReduction = -1
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
            // MODULE 1: 全局设置 (全宽卡片，内部双列)
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            settingsGroupCard(L("偏好", "Global Preferences"), icon: "slider.horizontal.3") {
                // Row 1: 三等分 - 提示音 / 录音动效 / 界面语言
                HStack(alignment: .top, spacing: 16) {
                    startSoundRow
                        .frame(maxWidth: .infinity)
                    visualStyleRow
                        .frame(maxWidth: .infinity)
                    languageRow
                        .frame(maxWidth: .infinity)
                }

                SettingsDivider()

                // Row 2: 两等分 - 开机启动 / 降低音量
                HStack(alignment: .top, spacing: 16) {
                    launchAtLoginRow
                        .frame(maxWidth: .infinity)
                    volumeReductionRow
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer().frame(height: 16)

            settingsGroupCard(L("系统权限", "Permissions"), icon: "lock.shield.fill") {
                HStack(spacing: 12) {
                    permissionBlock(
                        icon: "mic.fill", name: L("麦克风", "Microphone"), granted: hasMic
                    ) {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in
                                hasMic = granted
                                if !granted {
                                    NSWorkspace.shared.open(
                                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                                    )
                                }
                            }
                        }
                    }

                    permissionBlock(
                        icon: "accessibility", name: L("辅助功能", "Accessibility"), granted: hasAccessibility
                    ) {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        hasAccessibility = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }

            Spacer().frame(height: 16)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MODULE 2: API 设置 (上下结构)
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            ASRSettingsCard()

            Spacer().frame(height: 16)

            LLMSettingsCard()

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

    private func settingsToggleRow(_ label: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(L("提示音", "Start Sound").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $startSound,
                options: StartSoundStyle.allCases.map { ($0.rawValue, $0.displayName) }
            )
            .onChange(of: startSound) { _, newValue in
                if let style = StartSoundStyle(rawValue: newValue) {
                    SoundFeedback.previewStartSound(style)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var visualStyleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("录音动效", "Visual Style").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsSegmentedPicker(
                selection: $visualStyle,
                options: [
                    ("classic", L("线条", "Lines")),
                    ("dual", L("粒子云", "Blocks")),
                    ("timeline", L("电平", "Minimal")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("开机自动启动", "Launch at Startup").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { launchAtLogin ? "on" : "off" },
                    set: { launchAtLogin = $0 == "on" }
                ),
                options: [
                    ("on", L("开启", "On")),
                    ("off", L("关闭", "Off")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var volumeReductionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("录音时降低音量", "Lower System Volume").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: Binding(
                    get: { String(volumeReduction) },
                    set: { volumeReduction = Int($0) ?? -1 }
                ),
                options: [
                    ("-1", L("不降低", "Off")),
                    ("50", "50%"),
                    ("40", "40%"),
                    ("30", "30%"),
                    ("20", "20%"),
                    ("10", "10%"),
                    ("0", L("静音", "Mute")),
                ]
            )
        }
        .padding(.vertical, 6)
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("界面语言", "Primary Language").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: $language,
                options: AppLanguage.allCases.map { ($0.rawValue, $0.displayName) },
                icon: "globe"
            )
        }
        .padding(.vertical, 6)
    }

    // MARK: - Permission Block

    private func permissionBlock(
        icon: String,
        name: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(granted ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                )

            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)

            Spacer()

            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已授权", "Authorized"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
            } else {
                Button { action() } label: {
                    Text(L("授权", "Grant"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsAccentAmber))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
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
