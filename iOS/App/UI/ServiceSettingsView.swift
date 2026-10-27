import SwiftUI
import Type4MeTransferCore

/// Settings › Speech Service: every cloud speech service the Mac offers,
/// with the same fields, rendered from the Mac's provider configs. A service
/// synced from the Mac (or saved here before) comes back with its values when
/// it is picked again.
struct ASRSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ASRProvider
    @State private var values: [String: String]
    /// Picker fields switched to free typing ("Custom…").
    @State private var customInput: Set<String> = []
    @State private var test = ConnectionTest.State.idle
    @State private var saveError: String?
    @State private var confirmRemove = false

    /// Synced from the Mac and kept as is; not something to type on a phone.
    private static let hiddenKeys: Set<String> = ["boostingTableID"]
    private static let customTag = "_custom"

    init() {
        let saved = ConfigStore.asr
        let provider = saved.flatMap { ASRProvider(rawValue: $0.provider) }.flatMap { PhoneASR.entry(for: $0) != nil ? $0 : nil } ?? .volcano
        _provider = State(initialValue: provider)
        _values = State(initialValue: Self.values(for: provider))
    }

    /// Saved values for a provider, falling back to its defaults.
    private static func values(for provider: ASRProvider) -> [String: String] {
        if let saved = ConfigStore.profile(for: provider.rawValue, kind: .asr) { return saved.fields }
        var result: [String: String] = [:]
        for field in PhoneASR.entry(for: provider)?.configType.credentialFields ?? [] where !field.defaultValue.isEmpty {
            result[field.key] = field.defaultValue
        }
        return result
    }

    private var entry: PhoneASR.Entry? { PhoneASR.entry(for: provider) }
    private var allFields: [CredentialField] { entry?.configType.credentialFields ?? [] }

    /// Values with defaults filled in for anything not set yet.
    private var effectiveValues: [String: String] {
        var result = values
        for field in allFields where result[field.key] == nil && !field.defaultValue.isEmpty {
            result[field.key] = field.defaultValue
        }
        return result
    }

    private var modeField: CredentialField? {
        allFields.first { $0.key == ASRRecognitionMode.credentialKey }
    }

    /// Same rules as the Mac detail view: fields scoped to the chosen
    /// recognition mode, and Volcano's keys for the chosen authentication.
    private var shownFields: [CredentialField] {
        guard let configType = entry?.configType else { return [] }
        let effective = effectiveValues
        var fields = configType.displayedCredentialFields(for: effective)
            .filter { $0.key != ASRRecognitionMode.credentialKey && !Self.hiddenKeys.contains($0.key) }
        if provider == .volcano {
            let legacy = VolcanoASRConfig.inferredAuthMode(in: effective) == VolcanoASRConfig.authModeLegacy
            fields = fields.filter { field in
                switch field.key {
                case "apiKey": return !legacy
                case "appKey", "accessKey": return legacy
                default: return true
                }
            }
        }
        return fields
    }

    private var endpoint: Type4MeTransferPayload.Endpoint {
        let fields = effectiveValues
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        return .init(provider: provider.rawValue, fields: fields)
    }

    private var isComplete: Bool {
        let fields = endpoint.fields
        let required = shownFields.filter { !isOptional($0) }
        return PhoneASR.config(for: endpoint) != nil
            && required.allSatisfy { !(fields[$0.key] ?? "").isEmpty }
    }

    /// Volcano marks its keys optional because which ones are needed depends
    /// on the authentication; the ones shown for it are required.
    private func isOptional(_ field: CredentialField) -> Bool {
        if provider == .volcano, ["apiKey", "appKey", "accessKey"].contains(field.key) { return false }
        return field.isOptional
    }

    private var isUnchanged: Bool { ConfigStore.asr == endpoint }
    /// Providers saved on this iPhone, listed first in the picker.
    private var configuredProviders: Set<String> {
        Set(ConfigStore.profiles(.asr).map(\.provider) + [ConfigStore.asr?.provider].compactMap { $0 })
    }

    var body: some View {
        Form {
            Section {
                Picker(L("服务商", "Provider"), selection: $provider) {
                    let configured = configuredProviders
                    ProviderPickerItems(
                        configured: PhoneASR.providers.filter { configured.contains($0.rawValue) },
                        others: PhoneASR.providers.filter { !configured.contains($0.rawValue) }
                    ) { Text($0.displayName).tag($0) }
                }
                if let modeField {
                    Picker(modeField.label, selection: binding(for: modeField)) {
                        ForEach(modeField.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text(L("服务", "Service"))
            } footer: {
                Text(serviceFooter)
            }

            if !shownFields.isEmpty {
                Section {
                    ForEach(shownFields) { field in
                        fieldRow(field)
                    }
                } header: {
                    Text(L("设置", "Settings"))
                }
            }

            Section {
                ConnectionTestCard(state: test, isEnabled: isComplete) {
                    Task { await runTest() }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if ConfigStore.asr != nil {
                Section {
                    Button(L("删除识别服务", "Remove Speech Service"), role: .destructive) { confirmRemove = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("识别服务", "Speech Service"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("保存", "Save")) { save() }
                    .disabled(!isComplete || isUnchanged)
            }
        }
        .onChange(of: provider) { _, new in
            values = Self.values(for: new)
            customInput = []
        }
        .onChange(of: endpoint) { _, _ in test = .idle }
        .alert(L("保存失败", "Couldn't Save"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button(L("好", "OK")) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert(L("删除识别服务？", "Remove the speech service?"), isPresented: $confirmRemove) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除", "Remove"), role: .destructive) {
                session.endSession(reason: L("删除识别服务", "speech service removed"))
                ConfigStore.remove(.asr)
                model.configVersion += 1
                dismiss()
            }
        } message: {
            Text(L("密钥会从这台 iPhone 上删除，删除后无法录音。", "The keys will be removed from this iPhone and dictation will stop working."))
        }
    }

    private var serviceFooter: String {
        guard let entry else { return "" }
        let variant = entry.batch != nil && ASRRecognitionMode(credentials: effectiveValues) == .batch ? entry.batch! : entry.main
        var text = variant.isStreaming
            ? L("边说边出字。", "Text appears while you speak.")
            : L("松手后上传整段录音再识别。", "The whole recording is uploaded when you let go.")
        if provider == .volcano, !(values["boostingTableID"] ?? "").isEmpty {
            text += L("热词表已从 Mac 同步，会一起使用。", " The hotword table synced from your Mac is used too.")
        }
        return text
    }

    // MARK: - Fields

    private func binding(for field: CredentialField) -> Binding<String> {
        Binding(
            get: { effectiveValues[field.key] ?? "" },
            set: { values[field.key] = $0 }
        )
    }

    @ViewBuilder
    private func fieldRow(_ field: CredentialField) -> some View {
        let title = isOptional(field) ? L("\(field.label)（可选）", "\(field.label) (optional)") : field.label
        VStack(alignment: .leading, spacing: 4) {
            if !field.options.isEmpty {
                optionRow(field, title: title)
            } else if field.isMultiline {
                Text(title).font(.system(size: 13)).foregroundStyle(T4.secondary)
                TextField(field.placeholder, text: binding(for: field), axis: .vertical)
                    .lineLimit(2...6)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                Text(title).font(.system(size: 13)).foregroundStyle(T4.secondary)
                CredentialInput(title: field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(for: field), secret: field.isSecure)
            }
            if let hint = field.hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(T4.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ field: CredentialField, title: String) -> some View {
        let current = effectiveValues[field.key] ?? ""
        let isCustom = field.allowCustomInput
            && (customInput.contains(field.key) || (!current.isEmpty && !field.options.contains { $0.value == current }))
        Picker(title, selection: Binding(
            get: { isCustom ? Self.customTag : current },
            set: { value in
                if value == Self.customTag {
                    customInput.insert(field.key)
                } else {
                    customInput.remove(field.key)
                    values[field.key] = value
                }
            }
        )) {
            ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
            if field.allowCustomInput {
                Text(L("自定义…", "Custom…")).tag(Self.customTag)
            }
        }
        if isCustom {
            TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(for: field))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 15, design: .monospaced))
        }
    }

    private func runTest() async {
        test = .testing
        test = await PhoneASR.test(endpoint)
    }

    private func save() {
        do {
            try ConfigStore.save(endpoint, as: .asr)
            model.configVersion += 1
            model.log.add(L("已手动保存识别服务：\(provider.displayName)", "Speech service saved by hand: \(provider.displayName)"))
            model.didBecomeActive()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Settings › Text Model: every cloud text provider the Mac can export.
struct LLMSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var providerID: String
    @State private var apiKey: String
    @State private var modelName: String
    @State private var baseURL: String
    @State private var test = ConnectionTest.State.idle
    @State private var saveError: String?
    @State private var confirmRemove = false

    init() {
        let saved = ConfigStore.llm
        let id = saved.map(\.provider).flatMap { id in LLMProviderPreset.all.contains { $0.id == id } ? id : nil } ?? "deepseek"
        let preset = LLMProviderPreset.preset(for: id)
        _providerID = State(initialValue: id)
        _apiKey = State(initialValue: saved?.fields["apiKey"] ?? "")
        _modelName = State(initialValue: saved?.fields["model"] ?? preset.models.first ?? "")
        _baseURL = State(initialValue: saved?.fields["baseURL"] ?? preset.baseURL)
    }

    private var preset: LLMProviderPreset { LLMProviderPreset.preset(for: providerID) }
    /// Providers saved on this iPhone, listed first in the picker.
    private var configuredProviders: Set<String> {
        Set(ConfigStore.llmProfiles.map(\.provider) + [ConfigStore.llm?.provider].compactMap { $0 })
    }

    private var trimmedBaseURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An empty field falls back to the provider's default, so clearing an
    /// address synced from the Mac (a proxy, say) restores the default.
    private var effectiveBaseURL: String { trimmedBaseURL.isEmpty ? preset.baseURL : trimmedBaseURL }

    private var endpoint: Type4MeTransferPayload.Endpoint {
        preset.endpoint(apiKey: apiKey, model: modelName, baseURL: effectiveBaseURL)
    }

    private var config: LLMEndpointConfig? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              URL(string: effectiveBaseURL)?.scheme != nil
        else { return nil }
        return LLMEndpointConfig(endpoint: endpoint)
    }

    /// Hints are derived, so compare only what the user can edit.
    private var isUnchanged: Bool {
        guard let saved = ConfigStore.llm else { return false }
        return saved.provider == endpoint.provider
            && ["apiKey", "model", "baseURL"].allSatisfy { saved.fields[$0] == endpoint.fields[$0] }
    }

    var body: some View {
        Form {
            Section {
                Picker(L("服务商", "Provider"), selection: $providerID) {
                    let configured = configuredProviders
                    ProviderPickerItems(
                        configured: LLMProviderPreset.all.filter { configured.contains($0.id) },
                        others: LLMProviderPreset.all.filter { !configured.contains($0.id) }
                    ) { Text($0.name).tag($0.id) }
                }
                CredentialInput(title: "API Key", text: $apiKey, secret: true)
                HStack {
                    TextField(L("模型", "Model"), text: $modelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !preset.models.isEmpty {
                        Menu {
                            ForEach(preset.models, id: \.self) { name in
                                Button(name) { modelName = name }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(T4.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel(L("选择模型", "Choose a model"))
                    }
                }
            } header: {
                Text(L("服务", "Service"))
            }

            Section {
                TextField(L("接口地址", "Base URL"), text: $baseURL, prompt: Text(preset.isCustom ? "https://…/v1" : preset.baseURL))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 15, design: .monospaced))
                if !preset.isCustom, !trimmedBaseURL.isEmpty, trimmedBaseURL != preset.baseURL {
                    Button(L("恢复默认地址", "Restore Default URL")) { baseURL = preset.baseURL }
                }
            } header: {
                Text(L("接口地址", "Base URL"))
            } footer: {
                Text(preset.isCustom
                    ? L("填写 OpenAI 兼容接口的地址，会请求它的 /chat/completions。", "Enter an OpenAI-compatible base URL. Type4Me calls its /chat/completions.")
                    : preset.usesMessagesAPI
                        ? L("一般不用改，和 Mac 版默认一致，留空则使用默认地址。会请求它的 /messages。", "Usually no need to change this. It matches the Mac default; leave it empty to use the default. Type4Me calls its /messages.")
                        : L("一般不用改，和 Mac 版默认一致，留空则使用默认地址。", "Usually no need to change this. It matches the Mac default; leave it empty to use the default."))
            }

            Section {
                ConnectionTestCard(state: test, isEnabled: config != nil) {
                    Task { await runTest() }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if ConfigStore.llm != nil {
                Section {
                    Button(L("删除处理模型", "Remove Text Model"), role: .destructive) { confirmRemove = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("处理模型", "Text Model"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("保存", "Save")) { save() }
                    .disabled(config == nil || isUnchanged)
            }
        }
        .onChange(of: providerID) { old, new in
            let oldPreset = LLMProviderPreset.preset(for: old)
            let newPreset = LLMProviderPreset.preset(for: new)
            // A provider synced from the Mac (or saved here before) comes back
            // with its own key and model.
            if let saved = ConfigStore.profile(for: new) {
                apiKey = saved.fields["apiKey"] ?? ""
                modelName = saved.fields["model"] ?? newPreset.models.first ?? ""
                baseURL = saved.fields["baseURL"] ?? newPreset.baseURL
                return
            }
            if ConfigStore.profile(for: old) != nil { apiKey = "" }
            // Switch the defaults along with the provider, but keep anything typed by hand.
            if baseURL.isEmpty || baseURL == oldPreset.baseURL { baseURL = newPreset.baseURL }
            if modelName.isEmpty || oldPreset.models.contains(modelName) { modelName = newPreset.models.first ?? "" }
        }
        .onChange(of: endpoint) { _, _ in test = .idle }
        .alert(L("保存失败", "Couldn't Save"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button(L("好", "OK")) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert(L("删除处理模型？", "Remove the text model?"), isPresented: $confirmRemove) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除", "Remove"), role: .destructive) {
                ConfigStore.remove(.llm)
                model.configVersion += 1
                dismiss()
            }
        } message: {
            Text(L("密钥会从这台 iPhone 上删除，需要处理模型的模式会改用原文。", "The key will be removed from this iPhone. Modes that need a text model will use your original words."))
        }
    }

    private func runTest() async {
        guard let config else { return }
        test = .testing
        test = await ConnectionTest.llm(config)
    }

    private func save() {
        do {
            try ConfigStore.save(endpoint, as: .llm)
            model.configVersion += 1
            model.log.add(L("已手动保存处理模型：\(preset.name)", "Text model saved by hand: \(preset.name)"))
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A labelled credential row. Secrets stay masked until the eye is tapped.
struct CredentialInput: View {
    let title: String
    @Binding var text: String
    let secret: Bool
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if secret && !revealed {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .textContentType(.none)
            if secret {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(T4.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? L("隐藏", "Hide") : L("显示", "Show"))
            }
        }
    }
}

/// Test button and result in one card, below the form, so the outcome reads
/// as feedback on what was just entered rather than another setting.
struct ConnectionTestCard: View {
    let state: ConnectionTest.State
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T4.ink)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            Button(action: action) {
                Text(state == .testing ? L("正在测试…", "Testing…") : L("测试连接", "Test Connection"))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.glassProminent)
            .tint(T4.ink)
            .foregroundStyle(T4.background)
            .disabled(!isEnabled || state == .testing)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: T4.cornerCard, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .idle: Image(systemName: "network").foregroundStyle(T4.secondary)
        case .testing: ProgressView()
        case .passed: Image(systemName: "checkmark").foregroundStyle(T4.success)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T4.recording)
        }
    }

    private var title: String {
        switch state {
        case .idle: return L("连接测试", "Connection Test")
        case .testing: return L("正在连接…", "Connecting…")
        case .passed: return L("连接正常", "Connected")
        case .failed: return L("连接失败", "Connection Failed")
        }
    }

    private var detail: String {
        switch state {
        case .idle:
            return isEnabled
                ? L("用当前填写的内容试连一次，不用先保存。", "Tries what's filled in now. No need to save first.")
                : L("先填好上面的必填项。", "Fill in the required fields above first.")
        case .testing: return L("最多等 10 秒。", "This takes up to 10 seconds.")
        case .passed(let ms): return L("响应用时 \(ms) ms", "Responded in \(ms) ms")
        case .failed(let message): return message
        }
    }

    private var detailColor: Color {
        if case .failed = state { return T4.recording }
        return T4.secondary
    }
}

enum ConnectionTest {
    enum State: Equatable {
        case idle
        case testing
        case passed(ms: Int)
        case failed(String)
    }

    static func llm(_ config: LLMEndpointConfig) async -> State {
        let started = Date()
        do {
            _ = try await ChatClient(config: config).complete(system: nil, user: L("回复“好”。", "Reply with “OK”."), timeout: 10)
            return .passed(ms: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Provider picker contents: the ones saved on this iPhone first, under their
/// own heading, then the rest. Without any saved, a plain list as before.
private struct ProviderPickerItems<Item: Hashable, Row: View>: View {
    let configured: [Item]
    let others: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if configured.isEmpty {
            ForEach(others, id: \.self, content: row)
        } else {
            Section(L("已配置", "Set Up")) {
                ForEach(configured, id: \.self, content: row)
            }
            Section(L("其他服务商", "Other Providers")) {
                ForEach(others, id: \.self, content: row)
            }
        }
    }
}
