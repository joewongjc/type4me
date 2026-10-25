import SwiftUI
import Type4MeTransferCore

/// Settings › Hotwords: words the speech service should favor.
struct HotwordSettingsView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var draft = ""
    @State private var notice: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField(L("输入新的热词", "Enter a new hotword"), text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(canAdd ? T4.ink : T4.ink.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdd)
                    .accessibilityLabel(L("添加热词", "Add hotword"))
                }
            } footer: {
                Text(notice ?? L(
                    "人名、产品名、专业术语这类容易认错的词，加进来能提高识别准确率。",
                    "Add names, products and jargon that tend to be misheard, so recognition gets them right."
                ))
                .foregroundStyle(notice == nil ? T4.secondary : T4.recording)
            }

            if !store.hotwords.isEmpty {
                Section(L("\(store.hotwords.count) 个热词", "\(store.hotwords.count) hotwords")) {
                    ForEach(store.hotwords, id: \.self) { word in
                        Text(word).foregroundStyle(T4.ink)
                    }
                    .onDelete { store.deleteHotwords(at: $0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("热词", "Hotwords"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.hotwords.isEmpty { EditButton() }
        }
        .onChange(of: draft) { _, _ in notice = nil }
    }

    private var canAdd: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        if store.addHotword(draft) {
            draft = ""
            fieldFocused = true
        } else {
            notice = L("这个热词已经在列表里了。", "That hotword is already in the list.")
        }
    }
}

/// Settings › Snippets: spoken triggers replaced with fixed text.
struct SnippetSettingsView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var editing: SnippetEditTarget?

    var body: some View {
        List {
            Section {
                Button {
                    editing = SnippetEditTarget(index: nil, snippet: .init(trigger: "", replacement: ""))
                } label: {
                    Label(L("添加片段替换", "Add Snippet"), systemImage: "plus")
                }
            } footer: {
                Text(L(
                    "说到触发词时换成替换内容，不分大小写和空格。常用来纠正总认错的词，或者一句话说出一整段固定内容。",
                    "When you say a trigger, it's replaced with the text you set, ignoring case and spaces. Use it to fix words that are always misheard, or to insert a fixed passage with a short phrase."
                ))
            }

            if !store.snippets.isEmpty {
                Section(L("\(store.snippets.count) 条", "\(store.snippets.count) snippets")) {
                    ForEach(Array(store.snippets.enumerated()), id: \.offset) { index, snippet in
                        Button {
                            editing = SnippetEditTarget(index: index, snippet: snippet)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snippet.trigger)
                                    .foregroundStyle(T4.ink)
                                Text("→ " + snippet.replacement)
                                    .font(.system(size: 13))
                                    .foregroundStyle(T4.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("\(snippet.trigger)，替换为 \(snippet.replacement)", "\(snippet.trigger), replaced with \(snippet.replacement)"))
                    }
                    .onDelete { store.deleteSnippets(at: $0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("片段替换", "Snippets"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.snippets.isEmpty { EditButton() }
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                SnippetEditorView(target: target)
            }
            .presentationDetents([.medium])
        }
    }
}

struct SnippetEditTarget: Identifiable {
    let id = UUID()
    /// nil adds a new snippet.
    let index: Int?
    let snippet: Type4MeTransferPayload.Snippet
}

private struct SnippetEditorView: View {
    let target: SnippetEditTarget
    @ObservedObject private var store = VocabularyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var replacement: String
    @State private var notice: String?

    init(target: SnippetEditTarget) {
        self.target = target
        _trigger = State(initialValue: target.snippet.trigger)
        _replacement = State(initialValue: target.snippet.replacement)
    }

    var body: some View {
        Form {
            Section {
                TextField(L("触发词，比如 cloud code", "Trigger, e.g. cloud code"), text: $trigger)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L("替换为，比如 Claude Code", "Replace with, e.g. Claude Code"), text: $replacement, axis: .vertical)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
            } footer: {
                if let notice {
                    Text(notice).foregroundStyle(T4.recording)
                }
            }
        }
        .navigationTitle(target.index == nil ? L("添加片段替换", "Add Snippet") : L("编辑片段替换", "Edit Snippet"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("取消", "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("保存", "Save"), action: save)
                    .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        let snippet = Type4MeTransferPayload.Snippet(trigger: trigger, replacement: replacement)
        if store.saveSnippet(snippet, replacing: target.index) {
            dismiss()
        } else {
            notice = L("已经有一条用这个触发词的片段替换了。", "Another snippet already uses this trigger.")
        }
    }
}
