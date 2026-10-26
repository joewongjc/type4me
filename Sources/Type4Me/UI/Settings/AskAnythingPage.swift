import AppKit
import SwiftUI

enum AskAnythingDateFormatting {
    static func shortTime(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(for: language)
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func dateDescription(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(for: language)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func locale(for language: AppLanguage) -> Locale {
        language == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
    }
}

private enum AskAnythingDateGroupID: String, Hashable {
    case today
    case yesterday
    case lastSevenDays
    case lastThirtyDays
    case older

    var title: String {
        switch self {
        case .today: return L("今天", "TODAY")
        case .yesterday: return L("昨天", "YESTERDAY")
        case .lastSevenDays: return L("最近 7 天", "LAST 7 DAYS")
        case .lastThirtyDays: return L("最近 30 天", "LAST 30 DAYS")
        case .older: return L("更早", "OLDER")
        }
    }
}

private struct AskAnythingDateGroupHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct AskAnythingPage: View {
    let isActive: Bool

    @Environment(AskAnythingCoordinator.self) private var coordinator
    @Environment(AppNavigationModel.self) private var navigationModel
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    @State private var sessions: [AskAnythingSessionSummary] = []
    @State private var selectedSessionID: UUID?
    @State private var searchText = ""
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var refreshGeneration = 0
    @State private var renameText = ""
    @State private var showRenameDialog = false
    @State private var showDeleteConfirmation = false
    @State private var expandedSourceSessionIDs: Set<UUID> = []
    @State private var collapsedDateGroups: Set<AskAnythingDateGroupID> = []

    private let pageSize = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionHeader(
                label: "ASK ANYTHING",
                title: L("随便问", "Ask Anything"),
                description: L(
                    "查找过去的问题，并从任意会话继续语音追问。",
                    "Find past questions and continue any conversation by voice."
                )
            )

            if let displayedError = errorMessage ?? coordinator.persistenceError {
                Label(displayedError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsAccentRed)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(TF.settingsAccentRed.opacity(0.10))
                    )
            }

            HStack(spacing: 0) {
                conversationList
                    .frame(width: 300)
                Rectangle()
                    .fill(TF.settingsBorder)
                    .frame(width: 1)
                conversationDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(
                RoundedRectangle(cornerRadius: TF.cornerLG, style: .continuous)
                    .fill(TF.settingsCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: TF.cornerLG, style: .continuous)
                            .stroke(TF.settingsBorder, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: TF.cornerLG, style: .continuous))
        }
        .task(id: "\(isActive)-\(searchText)-\(refreshGeneration)") {
            guard isActive else { return }
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await loadFirstPage()
            await consumePendingNavigation()
        }
        .onChange(of: isActive) { _, active in
            if !active {
                isLoadingMore = false
            } else {
                Task { await consumePendingNavigation() }
            }
        }
        .onChange(of: navigationModel.pendingAskAnythingSessionID) { _, _ in
            guard isActive else { return }
            Task { await consumePendingNavigation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .askAnythingStoreDidChange)) { _ in
            guard isActive else { return }
            refreshGeneration &+= 1
        }
        .alert(L("重命名会话", "Rename Conversation"), isPresented: $showRenameDialog) {
            TextField(L("会话标题", "Conversation title"), text: $renameText)
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("保存", "Save")) {
                Task { await renameSelectedConversation() }
            }
        }
        .alert(L("删除会话", "Delete Conversation"), isPresented: $showDeleteConfirmation) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除", "Delete"), role: .destructive) {
                Task { await deleteSelectedConversation() }
            }
        } message: {
            Text(L(
                "此操作将删除该会话的选中文本、问题和回答，且无法恢复。",
                "This removes the selected text, questions, and answers. It cannot be undone."
            ))
        }
        .id(language)
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(TF.settingsTextTertiary)
                    TextField(L("搜索会话", "Search conversations"), text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.tfIcon(.chipRemove))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(TF.settingsCardAlt)
                )

                Button {
                    selectedSessionID = nil
                    coordinator.createEmptyDraftForMainWindow()
                } label: {
                    Label(L("新建会话", "New conversation"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.tf(.primary, size: .large, fillsWidth: true))
            }
            .padding(14)

            Rectangle().fill(TF.settingsBorder).frame(height: 1)

            if isLoading && sessions.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                listEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedSessions, id: \.id) { group in
                            Button {
                                if collapsedDateGroups.contains(group.id) {
                                    collapsedDateGroups.remove(group.id)
                                } else {
                                    collapsedDateGroups.insert(group.id)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .frame(width: 10, height: 10)
                                        .rotationEffect(.degrees(
                                            collapsedDateGroups.contains(group.id) ? -90 : 0
                                        ))
                                        .animation(
                                            .easeOut(duration: 0.14),
                                            value: collapsedDateGroups.contains(group.id)
                                        )
                                    Text(group.title)
                                        .tracking(0.7)
                                        .foregroundStyle(TF.settingsTextTertiary)
                                    Spacer()
                                    Text("\(group.sessions.count)")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(TF.settingsTextTertiary)
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(AskAnythingDateGroupHeaderButtonStyle())

                            if !collapsedDateGroups.contains(group.id) {
                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }

                        if hasMore && searchText.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .onAppear {
                                    guard isActive, !isLoadingMore else { return }
                                    Task { await loadMore() }
                                }
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .background(TF.settingsSidebar.opacity(0.55))
    }

    private var listEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "text.bubble" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(TF.settingsTextTertiary)
            Text(searchText.isEmpty
                 ? L("还没有会话", "No conversations yet")
                 : L("没有找到相关会话", "No matching conversations"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: AskAnythingSessionSummary) -> some View {
        Button {
            selectedSessionID = session.id
            Task { await selectSession(session.id) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)
                    Spacer()
                    Text(shortTime(session.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                if !session.lastAnswerPreview.isEmpty {
                    Text(session.lastAnswerPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(2)
                }
                Text(L("\(session.turnCount) 轮", "\(session.turnCount) turn(s)"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selectedSessionID == session.id ? TF.settingsSidebarActive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu {
            Button(L("重命名", "Rename")) {
                selectedSessionID = session.id
                renameText = session.title
                showRenameDialog = true
            }
            Button(L("删除", "Delete"), role: .destructive) {
                selectedSessionID = session.id
                showDeleteConfirmation = true
            }
            .disabled(isSessionBusy(session.id))
        }
    }

    @ViewBuilder
    private var conversationDetail: some View {
        if let conversation = coordinator.selectedConversation {
            activeConversationDetail(conversation)
        } else {
            newConversationState
        }
    }

    private func activeConversationDetail(_ conversation: AskAnythingConversation) -> some View {
        VStack(spacing: 0) {
            if let activeID = coordinator.activeBinding?.sessionID,
               activeID != conversation.session.id {
                Button {
                    selectedSessionID = activeID
                    Task { await selectSession(activeID) }
                } label: {
                    Label(
                        L("另一会话正在回答，点击返回", "Another conversation is answering — return"),
                        systemImage: "arrow.turn.up.left"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TF.settingsNavActive)
                .padding(.vertical, 8)
                .background(TF.settingsSidebarActive)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.session.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)
                    Text(dateDescription(conversation.session.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Spacer()
                Menu {
                    Button(L("重命名", "Rename")) {
                        renameText = conversation.session.title
                        showRenameDialog = true
                    }
                    Button(L("复制全部对话", "Copy full conversation")) {
                        copyConversation(conversation)
                    }
                    Divider()
                    Button(L("删除会话", "Delete conversation"), role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(isSessionBusy(conversation.session.id))
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            Rectangle().fill(TF.settingsBorder).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !conversation.session.sourceText.isEmpty {
                        sourceCard(conversation.session.sourceText, sessionID: conversation.session.id)
                    }
                    ForEach(conversation.turns) { turn in
                        turnCard(turn)
                    }
                    if coordinator.contextWasTruncated {
                        Label(
                            L("会话较长，后续回答将优先参考最近内容。", "This conversation is long; follow-ups prioritize recent content."),
                            systemImage: "info.circle"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(TF.settingsBorder).frame(height: 1)
            followUpBar(hasConversation: true)
        }
    }

    private var newConversationState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 34))
                .foregroundStyle(TF.settingsNavActive)
            VStack(spacing: 7) {
                Text(L("开始一个新问题", "Start a new question"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(TF.settingsText)
                Text(L(
                    "点击下方按钮，然后说出你想问的问题。\n如需针对其他应用的内容提问，请选中文字后使用快捷键。",
                    "Use the button below and speak your question.\nTo ask about another app, select its text and use the shortcut."
                ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            }
            followUpBar(hasConversation: false)
                .fixedSize()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceCard(_ source: String, sessionID: UUID) -> some View {
        let isExpanded = expandedSourceSessionIDs.contains(sessionID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("本会话基于此内容", "SOURCE FOR THIS CONVERSATION"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                copyButton(source)
            }
            Text(source)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .lineLimit(isExpanded ? nil : 8)
                .textSelection(.enabled)
            if source.count > 400 {
                Button(isExpanded ? L("收起", "Show less") : L("展开全文", "Show more")) {
                    if isExpanded {
                        expandedSourceSessionIDs.remove(sessionID)
                    } else {
                        expandedSourceSessionIDs.insert(sessionID)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsNavActive)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: TF.cornerMD, style: .continuous)
                .fill(TF.settingsCardAlt)
        )
    }

    private func turnCard(_ turn: AskAnythingTurn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("问题", "QUESTION"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(turn.question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                    .textSelection(.enabled)
            }
            .padding(14)

            Rectangle().fill(TF.settingsBorder).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("回答", "ANSWER"))
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(TF.settingsTextTertiary)
                    Spacer()
                    if !turn.answer.isEmpty { copyButton(turn.answer) }
                }
                if let error = turn.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentRed)
                        .textSelection(.enabled)
                } else if turn.status == .pending || (turn.status == .streaming && turn.answer.isEmpty) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("正在思考…", "Thinking…"))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                } else {
                    if turn.status == .interrupted {
                        Label(L("回答未完成", "Answer interrupted"), systemImage: "exclamationmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsAccentAmber)
                    }
                    ForEach(Array(MarkdownRenderer.displayBlocks(from: turn.answer).enumerated()), id: \.offset) { _, block in
                        Text(MarkdownRenderer.attributedString(from: block))
                            .font(.system(size: 13))
                            .foregroundStyle(TF.settingsText)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: TF.cornerMD, style: .continuous)
                .fill(TF.settingsCard)
                .overlay(
                    RoundedRectangle(cornerRadius: TF.cornerMD, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )
        )
    }

    private func followUpBar(hasConversation: Bool) -> some View {
        HStack(spacing: 10) {
            if coordinator.isRecordingFollowUp {
                Button(L("取消追问", "Cancel")) {
                    _ = coordinator.cancelActiveFollowUp()
                }
                .buttonStyle(.tf(.secondary))

                Button(L("结束追问", "Finish follow-up")) {
                    _ = coordinator.finishActiveFollowUp()
                }
                .buttonStyle(.tf(.primary))
            } else {
                Button {
                    if hasConversation {
                        _ = coordinator.startFollowUpRecording()
                    } else {
                        _ = coordinator.startNewQuestionRecording()
                    }
                } label: {
                    Label(
                        hasConversation ? L("继续追问", "Ask follow-up") : L("开始提问", "Start asking"),
                        systemImage: "mic.fill"
                    )
                }
                .buttonStyle(.tf(.primary))
            }
        }
        .padding(.horizontal, hasConversation ? 20 : 0)
        .frame(height: hasConversation ? 62 : nil)
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.tfIcon())
        .settingsTooltip(L("复制", "Copy"))
    }

    private var groupedSessions: [(id: AskAnythingDateGroupID, title: String, sessions: [AskAnythingSessionSummary])] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let sevenDays = calendar.date(byAdding: .day, value: -7, to: today)!
        let thirtyDays = calendar.date(byAdding: .day, value: -30, to: today)!
        let definitions: [(AskAnythingDateGroupID, (Date) -> Bool)] = [
            (.today, { $0 >= today }),
            (.yesterday, { $0 >= yesterday && $0 < today }),
            (.lastSevenDays, { $0 >= sevenDays && $0 < yesterday }),
            (.lastThirtyDays, { $0 >= thirtyDays && $0 < sevenDays }),
            (.older, { $0 < thirtyDays }),
        ]
        return definitions.compactMap { id, predicate in
            let matches = sessions.filter { predicate($0.updatedAt) }
            return matches.isEmpty ? nil : (id, id.title, matches)
        }
    }

    private func loadFirstPage() async {
        guard isActive else { return }
        isLoading = true
        errorMessage = nil
        do {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sessions = try await coordinator.fetchSessions(pageSize: pageSize)
                hasMore = sessions.count == pageSize
            } else {
                sessions = try await coordinator.searchSessions(query: searchText)
                hasMore = false
            }
            if selectedSessionID == nil,
               let selectedID = coordinator.selectedConversation?.session.id {
                selectedSessionID = selectedID
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard isActive, hasMore, !isLoadingMore, let last = sessions.last else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await coordinator.fetchSessions(
                pageSize: pageSize,
                before: AskAnythingSessionCursor(updatedAt: last.updatedAt, id: last.id)
            )
            sessions.append(contentsOf: next.filter { item in
                !sessions.contains(where: { $0.id == item.id })
            })
            hasMore = next.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func consumePendingNavigation() async {
        guard isActive, let id = navigationModel.pendingAskAnythingSessionID else { return }
        navigationModel.pendingAskAnythingSessionID = nil
        selectedSessionID = id
        await selectSession(id)
    }

    private func selectSession(_ id: UUID) async {
        do {
            try await coordinator.selectSession(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renameSelectedConversation() async {
        guard let id = selectedSessionID else { return }
        do {
            try await coordinator.renameSession(id: id, title: renameText)
            refreshGeneration &+= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedConversation() async {
        guard let id = selectedSessionID else { return }
        do {
            try await coordinator.deleteSession(id: id)
            selectedSessionID = nil
            refreshGeneration &+= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isSessionBusy(_ id: UUID) -> Bool {
        coordinator.activeBinding?.sessionID == id
            || (coordinator.isRecordingFollowUp && coordinator.activeConversation?.session.id == id)
    }

    private func copyConversation(_ conversation: AskAnythingConversation) {
        let text = conversation.turns.map { turn in
            "\(L("问题", "Question")): \(turn.question)\n\(L("回答", "Answer")): \(turn.answer)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func shortTime(_ date: Date) -> String {
        AskAnythingDateFormatting.shortTime(date, language: appLanguage)
    }

    private func dateDescription(_ date: Date) -> String {
        AskAnythingDateFormatting.dateDescription(date, language: appLanguage)
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .en
    }
}
