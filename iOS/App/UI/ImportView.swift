import SwiftUI
import Type4MeTransferCore

/// Shows what a sync from the Mac contains and lets the user pick what to
/// take: any of the speech services and text models (one of each active),
/// modes, hotwords and snippets.
struct ImportView: View {
    let payload: Type4MeTransferPayload
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ConfigStore.ImportSelection
    @State private var errorMessage: String?
    @State private var didImport = false

    init(payload: Type4MeTransferPayload) {
        self.payload = payload
        _selection = State(initialValue: ConfigStore.ImportSelection(all: payload))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L(
                    "来自 \(payload.sourceName ?? "Mac")。勾选要同步到这台 iPhone 的内容。",
                    "From \(payload.sourceName ?? "Mac"). Check what to sync to this iPhone."
                ))
                .font(.system(size: 15))
                .foregroundStyle(T4.secondary)
                .fixedSize(horizontal: false, vertical: true)
                preview(payload, selection: $selection)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(T4.recording)
                }

                Text(L("密钥只保存在这台 iPhone 的钥匙串里，不经过任何服务器。", "Keys are stored only in this iPhone's Keychain and never pass through a server."))
                    .font(.system(size: 13))
                    .foregroundStyle(T4.secondary)
            }
            .padding(20)
        }
        .background(DottedCanvas())
        .navigationTitle(L("从 Mac 同步", "Sync from Mac"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("取消", "Cancel")) { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(didImport ? L("已同步", "Synced") : L("同步所选内容", "Sync Selected")) { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(didImport || selection.isEmpty)
                .opacity(selection.isEmpty ? 0.4 : 1)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Preview

    private func preview(_ payload: Type4MeTransferPayload, selection: Binding<ConfigStore.ImportSelection>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let asrs = payload.allASRs
            if !asrs.isEmpty {
                group(
                    L("识别服务", "Speech Services"),
                    note: asrs.count > 1 ? L("「默认」的那个会直接启用，其他的可以在「设置 › 识别服务」里切换。", "The one marked Default is used right away; switch to the others in Settings › Speech Service.") : nil
                ) {
                    serviceRows(
                        asrs,
                        chosen: selection.asrs,
                        active: selection.activeASR,
                        name: ProviderNames.asr,
                        detail: PhoneASR.summary(for:),
                        warning: { PhoneASR.config(for: $0) == nil ? L("配置不完整，导入后无法录音。", "Incomplete; dictation won't work after importing.") : nil }
                    )
                }
            }

            let llms = payload.allLLMs
            if !llms.isEmpty {
                group(
                    L("处理模型", "Text Models"),
                    note: llms.count > 1 ? L("「默认」的那个会直接启用，其他的可以在「设置 › 处理模型」里切换。", "The one marked Default is used right away; switch to the others in Settings › Text Model.") : nil
                ) {
                    serviceRows(
                        llms,
                        chosen: selection.llms,
                        active: selection.activeLLM,
                        name: ProviderNames.llm,
                        detail: { $0.fields["model"] ?? "" },
                        warning: { LLMEndpointConfig(endpoint: $0) == nil ? L("配置不完整。", "Incomplete.") : nil }
                    )
                }
            }

            if let modes = payload.modes, !modes.isEmpty {
                group(
                    L("模式", "Modes"),
                    note: L("同名的模式会更新；新模式加到模式列表里，键盘上有空位时会直接放上去。", "Existing modes are updated. New ones join the mode list and go on the keyboard if there's room.")
                ) {
                    ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                        if index > 0 { Divider().overlay(T4.border) }
                        let exists = ModeLibrary.definition(for: localID(of: mode)) != nil
                        checkRow(
                            title: displayName(of: mode),
                            detail: detail(of: mode),
                            isOn: Binding(
                                get: { selection.wrappedValue.modes.contains(mode.id) },
                                set: { on in
                                    if on { selection.wrappedValue.modes.insert(mode.id) } else { selection.wrappedValue.modes.remove(mode.id) }
                                }
                            ),
                            warning: nil
                        ) {
                            T4Badge(text: exists ? L("更新", "Update") : L("新增", "New"))
                        }
                    }
                }
            }

            let hotwords = payload.hotwords ?? []
            let snippets = payload.snippets ?? []
            if !hotwords.isEmpty || !snippets.isEmpty {
                group(
                    L("词汇", "Vocabulary"),
                    note: L("和这台 iPhone 上已有的合并，不会删除你在手机上加的词。", "Merged with what's on this iPhone; nothing you added here is removed.")
                ) {
                    if !hotwords.isEmpty {
                        checkRow(
                            title: L("热词", "Hotwords"),
                            detail: hotwordDetail(hotwords),
                            isOn: selection.hotwords,
                            warning: nil
                        )
                    }
                    if !hotwords.isEmpty && !snippets.isEmpty { Divider().overlay(T4.border) }
                    if !snippets.isEmpty {
                        checkRow(
                            title: L("片段替换", "Snippets"),
                            detail: snippetDetail(snippets),
                            isOn: selection.snippets,
                            warning: nil
                        )
                    }
                }
            }

            if let textOutput = payload.textOutput {
                group(
                    L("文本输出", "Text Output"),
                    note: L("替换这台 iPhone 上的文本输出设置。", "Replaces the text output settings on this iPhone.")
                ) {
                    checkRow(
                        title: L("标点与空格", "Punctuation and Spacing"),
                        detail: TextOutputSettings.summary(textOutput),
                        isOn: selection.textOutput,
                        warning: nil
                    )
                }
            }
        }
    }

    private func hotwordDetail(_ words: [String]) -> String {
        let added = VocabularyStore.shared.preview(hotwords: words).added
        return L("\(words.count) 个，新增 \(added) 个", "\(words.count) · \(added) new")
    }

    private func snippetDetail(_ snippets: [Type4MeTransferPayload.Snippet]) -> String {
        let count = VocabularyStore.shared.preview(snippets: snippets)
        if count.updated > 0 {
            return L(
                "\(snippets.count) 条，新增 \(count.added) 条，更新 \(count.updated) 条",
                "\(snippets.count) · \(count.added) new · \(count.updated) updated"
            )
        }
        return L("\(snippets.count) 条，新增 \(count.added) 条", "\(snippets.count) · \(count.added) new")
    }

    /// Checkable services with one chosen row marked Default.
    private func serviceRows(
        _ endpoints: [Type4MeTransferPayload.Endpoint],
        chosen: Binding<Set<String>>,
        active: Binding<String?>,
        name: @escaping (String) -> String,
        detail: @escaping (Type4MeTransferPayload.Endpoint) -> String,
        warning: @escaping (Type4MeTransferPayload.Endpoint) -> String?
    ) -> some View {
        ForEach(Array(endpoints.enumerated()), id: \.element.provider) { index, endpoint in
            if index > 0 { Divider().overlay(T4.border) }
            let isOn = Binding(
                get: { chosen.wrappedValue.contains(endpoint.provider) },
                set: { on in
                    if on { chosen.wrappedValue.insert(endpoint.provider) } else { chosen.wrappedValue.remove(endpoint.provider) }
                    if !chosen.wrappedValue.contains(active.wrappedValue ?? "") {
                        active.wrappedValue = endpoints.map(\.provider).first(where: chosen.wrappedValue.contains)
                    }
                }
            )
            checkRow(title: name(endpoint.provider), detail: detail(endpoint), isOn: isOn, warning: warning(endpoint)) {
                if endpoints.count > 1, isOn.wrappedValue {
                    if active.wrappedValue == endpoint.provider {
                        Text(L("默认", "Default"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(T4.success)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(T4.success.opacity(0.12), in: Capsule())
                    } else {
                        Button(L("设为默认", "Make Default")) { active.wrappedValue = endpoint.provider }
                            .font(.system(size: 12, weight: .medium))
                            .buttonStyle(.glass)
                            .tint(T4.ink)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func localID(of mode: Type4MeTransferPayload.Mode) -> String {
        ModeDefinition.Kind(rawValue: mode.kind).map { $0 == .custom ? mode.id : $0.rawValue } ?? mode.id
    }

    private func target(of mode: Type4MeTransferPayload.Mode) -> TranslationLanguage {
        mode.targetLanguage.flatMap(TranslationLanguage.init(rawValue:)) ?? .english
    }

    private func displayName(of mode: Type4MeTransferPayload.Mode) -> String {
        if let kind = ModeDefinition.Kind(rawValue: mode.kind), kind != .custom {
            return mode.name ?? ModeDefinition.builtInName(kind, target: target(of: mode))
        }
        return mode.name ?? mode.id
    }

    private func detail(of mode: Type4MeTransferPayload.Mode) -> String {
        switch ModeDefinition.Kind(rawValue: mode.kind) {
        case .custom, nil:
            return mode.prompt.map { String($0.prefix(40)) } ?? ""
        case .translation:
            return L("内置模式 · 目标：\(target(of: mode).displayName)", "Built-in · Target: \(target(of: mode).displayName)")
        default:
            return L("内置模式", "Built-in mode")
        }
    }

    private func group<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(T4.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .t4Card(padding: 14)
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(T4.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func checkRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        warning: String?,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn.wrappedValue ? T4.ink : T4.ink.opacity(0.25))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T4.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(T4.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let warning {
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(T4.recording)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    private func save() {
        do {
            try model.importConfig(payload, selection: selection)
            didImport = true
            errorMessage = nil
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
            }
        } catch {
            errorMessage = L("保存失败：\(error.localizedDescription)", "Couldn't save: \(error.localizedDescription)")
        }
    }
}
