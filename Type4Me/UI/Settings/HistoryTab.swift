import SwiftUI
import Type4MeIntelliSenseCore

// MARK: - Model

struct HistoryRecord: Identifiable, Hashable {
    let id: String
    let createdAt: Date
    let durationSeconds: Double
    let rawText: String
    let processingMode: String?
    let processedText: String?
    let finalText: String
    let status: String
    let characterCount: Int?
    let asrProvider: String?
    let asrModel: String?
    let llmProvider: String?
    let llmModel: String?
    let asrDurationSeconds: Double?
    let llmDurationSeconds: Double?
    /// Versioned, privacy-safe JSON. Decoded only when an Intelli Sense row is expanded.
    let intelliSenseTraceJSON: String?
    let userEditedText: String?
    let userEditStatus: UserEditObservationStatus?
    let userEditObservedAt: Date?
    let userEditVersion: Int?

    init(
        id: String,
        createdAt: Date,
        durationSeconds: Double,
        rawText: String,
        processingMode: String?,
        processedText: String?,
        finalText: String,
        status: String,
        characterCount: Int?,
        asrProvider: String?,
        asrModel: String? = nil,
        llmProvider: String? = nil,
        llmModel: String? = nil,
        asrDurationSeconds: Double? = nil,
        llmDurationSeconds: Double? = nil,
        intelliSenseTraceJSON: String? = nil,
        userEditedText: String? = nil,
        userEditStatus: UserEditObservationStatus? = nil,
        userEditObservedAt: Date? = nil,
        userEditVersion: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.processingMode = processingMode
        self.processedText = processedText
        self.finalText = finalText
        self.status = status
        self.characterCount = characterCount
        self.asrProvider = asrProvider
        self.asrModel = asrModel
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.asrDurationSeconds = asrDurationSeconds
        self.llmDurationSeconds = llmDurationSeconds
        self.intelliSenseTraceJSON = intelliSenseTraceJSON
        self.userEditedText = userEditedText
        self.userEditStatus = userEditStatus
        self.userEditObservedAt = userEditObservedAt
        self.userEditVersion = userEditVersion
    }
}

// MARK: - Date Filter

enum DateFilter: Equatable, Hashable {
    case all, today, yesterday, thisWeek, thisMonth
    case custom(from: Date, to: Date)

    /// Convert to ISO8601 start/end strings for SQL queries. nil means no filter.
    var dateRange: (start: String, end: String)? {
        let cal = Calendar.current
        let now = Date()
        let iso = ISO8601DateFormatter()
        let pair: (Date, Date)?
        switch self {
        case .all:
            return nil
        case .today:
            let s = cal.startOfDay(for: now)
            pair = (s, cal.date(byAdding: .day, value: 1, to: s)!)
        case .yesterday:
            let todayStart = cal.startOfDay(for: now)
            pair = (cal.date(byAdding: .day, value: -1, to: todayStart)!, todayStart)
        case .thisWeek:
            let weekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
            pair = (weekStart, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!)
        case .thisMonth:
            let monthStart = cal.dateInterval(of: .month, for: now)!.start
            pair = (monthStart, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!)
        case .custom(let from, let to):
            let s = cal.startOfDay(for: from)
            pair = (s, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!)
        }
        guard let (s, e) = pair else { return nil }
        return (iso.string(from: s), iso.string(from: e))
    }

    var label: String {
        switch self {
        case .all: return L("全部", "All")
        case .today: return L("今天", "Today")
        case .yesterday: return L("昨天", "Yesterday")
        case .thisWeek: return L("本周", "This Week")
        case .thisMonth: return L("本月", "This Month")
        case .custom(let from, let to):
            let df = DateFormatter()
            df.dateFormat = "M/d"
            if Calendar.current.isDate(from, inSameDayAs: to) {
                return df.string(from: from)
            }
            return "\(df.string(from: from))-\(df.string(from: to))"
        }
    }
}

// MARK: - History Controls

/// Presents record-action tooltips in a tiny non-activating AppKit panel.
/// Because the panel is not a child of the ScrollView, it can extend beyond
/// the list viewport without clipping or per-frame scroll geometry work.
@MainActor
private final class HistoryFloatingTooltipController {
    static let shared = HistoryFloatingTooltipController()

    private var panel: NSPanel?
    private var activeOwner: UUID?

    func show(text: String, owner: UUID) {
        hide()

        let hostingView = NSHostingView(rootView: SettingsTooltipBubble(text: text))
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.fittingSize
        size.width = max(size.width, 44)
        size.height = 34
        hostingView.frame = NSRect(origin: .zero, size: size)

        let tooltipPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tooltipPanel.backgroundColor = .clear
        tooltipPanel.isOpaque = false
        tooltipPanel.hasShadow = true
        tooltipPanel.level = .floating
        tooltipPanel.ignoresMouseEvents = true
        tooltipPanel.collectionBehavior = [.transient, .ignoresCycle]
        tooltipPanel.contentView = hostingView

        let mouse = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.contains(mouse) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: mouse.x - size.width / 2,
            y: mouse.y - size.height - 18
        )
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        if origin.y < screenFrame.minY + 8 {
            origin.y = mouse.y + 18
        }
        origin.y = min(
            max(origin.y, screenFrame.minY + 8),
            screenFrame.maxY - size.height - 8
        )

        tooltipPanel.setFrameOrigin(origin)
        tooltipPanel.orderFrontRegardless()
        panel = tooltipPanel
        activeOwner = owner
    }

    func hide(owner: UUID? = nil) {
        if let owner, owner != activeOwner { return }
        panel?.orderOut(nil)
        panel = nil
        activeOwner = nil
    }
}

private struct HistoryFloatingTooltipModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    HistoryFloatingTooltipController.shared.show(text: text, owner: owner)
                } else {
                    HistoryFloatingTooltipController.shared.hide(owner: owner)
                }
            }
            .onDisappear {
                HistoryFloatingTooltipController.shared.hide(owner: owner)
            }
    }
}

private extension View {
    func historyFloatingTooltip(_ text: String) -> some View {
        modifier(HistoryFloatingTooltipModifier(text: text))
    }
}

private struct HistoryToolbarButton: View {
    let icon: String
    let tooltip: String
    var isEnabled = true
    var tooltipEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered && isEnabled
                              ? TF.settingsControlHover
                              : TF.settingsControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .settingsTooltip(tooltip, isEnabled: tooltipEnabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
            if hovering && isEnabled {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

/// Keeps row hover state local to the visible row. The content always reserves
/// the same trailing action area, so moving across rows never invalidates the
/// entire history page or changes text layout during scrolling.
private struct HistoryHoverSurface<Content: View, Controls: View>: View {
    let isSelectionMode: Bool
    @ViewBuilder let controls: (Bool) -> Controls
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isHovered
                    ? TF.settingsRowHover
                    : Color.clear
            )
            .overlay(alignment: .topTrailing) {
                if !isSelectionMode {
                    controls(isHovered)
                        .padding(.top, 10)
                        .padding(.trailing, 14)
                }
            }
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - View

struct HistoryTab: View {

    let isActive: Bool

    private let historyStore = HistoryStore()

    @State private var records: [HistoryRecord] = []
    @State private var sections: [DateSection] = []
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var searchText = ""
    @State private var copiedId: String?
    @State private var expandedRecordIds: Set<String> = []
    @State private var statistics: HistoryStore.Statistics?
    @State private var usageBreakdown: [HistoryStore.UsageBreakdown] = []
    @State private var usageBreakdownLoading = false
    @State private var showUsageDetails = false

    private static let pageSize = 50

    // Correction
    @State private var correctionRecord: HistoryRecord? = nil

    // Export
    @State private var showExportPopover = false
    @State private var exportRangeAll = true
    @State private var exportStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var exportEnd = Date()
    @State private var exportRecordCount: Int = 0

    // Date filter
    @State private var dateFilter: DateFilter = .all
    @State private var showCustomRange = false
    @State private var customRangeStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customRangeEnd = Date()

    // Batch selection
    @State private var isSelectionMode = false
    @State private var selectedIds: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    /// All record ids currently visible in the list (after search filter).
    /// Backed by the cached `sections`, so this is O(n) over loaded records
    /// only when accessed (toolbar buttons), not on every body re-render.
    private var visibleIds: Set<String> {
        Set(sections.flatMap { $0.records.map(\.id) })
    }

    /// True when every row in the current list (loaded + search filter) is selected.
    private var isAllFilteredSelected: Bool {
        HistorySelectionHelpers.isAllFilteredSelected(
            filteredIds: visibleIds,
            selectedIds: selectedIds
        )
    }

    // MARK: - Per-Day Grouping

    private struct DayGroup: Hashable {
        let date: Date  // start of day

        var title: String {
            let cal = Calendar.current
            let now = Date()
            if cal.isDateInToday(date) { return L("今天", "Today") }
            if cal.isDateInYesterday(date) { return L("昨天", "Yesterday") }

            let df = DateFormatter()
            let isZh = AppLanguage.current == .zh
            df.locale = isZh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")

            if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date > weekAgo {
                df.dateFormat = "EEEE"
                return df.string(from: date)
            }
            if cal.component(.year, from: date) == cal.component(.year, from: now) {
                df.dateFormat = isZh ? "M月d日 (EEE)" : "MMM d (EEE)"
            } else {
                df.dateFormat = isZh ? "yyyy年M月d日 (EEE)" : "MMM d, yyyy (EEE)"
            }
            return df.string(from: date)
        }
    }

    /// One day's worth of records, used as a `LazyVStack` `Section` so each
    /// header and row stays lazy. Identified by the day's start date.
    private struct DateSection: Identifiable {
        let id: Date
        let group: DayGroup
        let records: [HistoryRecord]
    }

    /// Recomputes `sections` from the current `records` and `searchText`.
    /// Called on data-changing events (record load, search change) so the
    /// view body never has to re-filter / re-group / re-sort during scroll.
    private func recomputeSections() {
        let baseRecords: [HistoryRecord]
        if searchText.isEmpty {
            baseRecords = records
        } else {
            baseRecords = records.filter {
                $0.finalText.localizedCaseInsensitiveContains(searchText)
                || $0.rawText.localizedCaseInsensitiveContains(searchText)
            }
        }
        let cal = Calendar.current
        let grouped = Dictionary(grouping: baseRecords) {
            DayGroup(date: cal.startOfDay(for: $0.createdAt))
        }
        sections = grouped
            .map { DateSection(id: $0.key.date, group: $0.key, records: $0.value) }
            .sorted { $0.id > $1.id }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: L("历史", "HISTORY"),
                title: L("识别历史", "History"),
                description: L("浏览和管理语音识别记录。", "Browse and manage speech recognition records.")
            )

            // Statistics Section
            if let stats = statistics, stats.recordCount > 0 {
                statisticsSection(stats: stats)
                    .padding(.bottom, TF.spacingMD)
                    .zIndex(30)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsTextTertiary)
                    TextField(L("搜索记录...", "Search..."), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )

                Menu {
                    let presets: [DateFilter] = [.all, .today, .yesterday, .thisWeek, .thisMonth]
                    ForEach(presets, id: \.self) { filter in
                        Button {
                            dateFilter = filter
                        } label: {
                            if dateFilter == filter {
                                Label(filter.label, systemImage: "checkmark")
                            } else {
                                Text(filter.label)
                            }
                        }
                    }
                    Divider()
                    Button {
                        showCustomRange = true
                    } label: {
                        if case .custom = dateFilter {
                            Label(L("自定义范围...", "Custom range..."), systemImage: "checkmark")
                        } else {
                            Text(L("自定义范围...", "Custom range..."))
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .semibold))
                        Text(dateFilter.label)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(dateFilter == .all ? TF.settingsTextSecondary : TF.settingsNavActive)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(dateFilter == .all ? TF.settingsBorder : TF.settingsText.opacity(0.18), lineWidth: 1)
                )
                .popover(isPresented: $showCustomRange, arrowEdge: .bottom) {
                    customRangePopover
                }

                HistoryToolbarButton(
                    icon: isSelectionMode ? "checkmark" : "checklist",
                    tooltip: isSelectionMode ? L("完成选择", "Finish selecting") : L("批量选择", "Select records"),
                    isEnabled: !records.isEmpty
                ) {
                    if isSelectionMode {
                        isSelectionMode = false
                        selectedIds.removeAll()
                    } else {
                        expandedRecordIds.removeAll()
                        isSelectionMode = true
                    }
                }

                HistoryToolbarButton(
                    icon: "square.and.arrow.up",
                    tooltip: L("导出记录", "Export records"),
                    isEnabled: !records.isEmpty && !isSelectionMode,
                    tooltipEnabled: !showExportPopover
                ) {
                    showExportPopover = true
                }
                .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
                    exportPopover
                }
            }
            .padding(.bottom, isSelectionMode ? 8 : 12)
            .zIndex(20)

            if isSelectionMode && !records.isEmpty {
                batchSelectionBar
                    .padding(.bottom, 12)
            }

            if records.isEmpty {
                emptyState
            } else if sections.isEmpty {
                Text(L("没有匹配的记录", "No matching records"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionHeaderView(section)
                                .padding(.top, section.id == sections.first?.id ? 0 : 14)
                                .padding(.bottom, 8)

                            ForEach(Array(section.records.enumerated()), id: \.element.id) { index, record in
                                historySectionRow(
                                    record,
                                    index: index,
                                    count: section.records.count
                                )
                            }
                        }

                        if hasMore && searchText.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .onAppear {
                                    guard !isLoadingMore else { return }
                                    Task { await loadMore() }
                                }
                            }
                        }
                    .padding(.bottom, 16)
                }
            }
        }
        .task {
            await loadRecords()
            await loadStatistics()
        }
        .onChange(of: isActive) { _, newValue in
            if !newValue {
                isSelectionMode = false
                selectedIds.removeAll()
                return
            }
            Task {
                await loadRecords()
                await loadStatistics()
            }
        }
        .onChange(of: dateFilter) { _, _ in
            selectedIds.removeAll()
            Task {
                await loadRecords()
                await loadStatistics()
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedIds.removeAll()
            recomputeSections()
        }
        .onChange(of: records) { _, _ in
            recomputeSections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            guard isActive else { return }
            Task {
                await loadRecords()
                await loadStatistics()
            }
        }
        .sheet(item: $correctionRecord) { record in
            QuickCorrectionSheet(text: record.rawText)
        }
        .alert(L("删除所选记录", "Delete selected records"), isPresented: $showBatchDeleteConfirm) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除", "Delete"), role: .destructive) {
                Task { await performBatchDelete() }
            }
        } message: {
            Text(
                L(
                    "将永久删除 \(selectedIds.count) 条记录，且无法恢复。",
                    "Permanently delete \(selectedIds.count) record(s)? This cannot be undone."
                )
            )
        }
    }

    private var batchSelectionBar: some View {
        HStack(spacing: 8) {
            Text(L("已选 \(selectedIds.count) 条", "\(selectedIds.count) selected"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)

            Spacer()

            Button {
                selectedIds = HistorySelectionHelpers.togglingSelectAllInFiltered(
                    filteredIds: visibleIds,
                    selectedIds: selectedIds
                )
            } label: {
                Text(
                    isAllFilteredSelected
                        ? L("取消全选", "Deselect All")
                        : L("全选当前列表", "Select All in List")
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsControl)
                )
            }
            .buttonStyle(.plain)
            .disabled(sections.isEmpty)

            Button {
                showBatchDeleteConfirm = true
            } label: {
                Text(L("删除", "Delete"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsAccentRed)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(TF.settingsAccentRed.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty)
            .opacity(selectedIds.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TF.settingsCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )
        )
    }

    private func performBatchDelete() async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        await historyStore.delete(ids: ids)
        await MainActor.run {
            isSelectionMode = false
            selectedIds.removeAll()
            showBatchDeleteConfirm = false
        }
    }

    private func toggleSelection(for id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func loadRecords() async {
        let range = dateFilter.dateRange
        let fetched = await historyStore.fetchPage(limit: Self.pageSize, from: range?.start, to: range?.end)
        records = fetched
        hasMore = fetched.count >= Self.pageSize
    }

    private func loadStatistics() async {
        let range = dateFilter.dateRange
        let stats = await historyStore.getStatistics(from: range?.start, to: range?.end)
        statistics = stats
        if showUsageDetails {
            await loadUsageBreakdown()
        }
    }

    private func loadUsageBreakdown() async {
        usageBreakdownLoading = true
        let rows = await historyStore.getUsageBreakdown()
        usageBreakdown = rows
        usageBreakdownLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let cursor = records.last.map { ISO8601DateFormatter().string(from: $0.createdAt) } ?? ""
        guard !cursor.isEmpty else {
            isLoadingMore = false
            return
        }
        let range = dateFilter.dateRange
        let page = await historyStore.fetchPage(limit: Self.pageSize, before: cursor, from: range?.start)
        records.append(contentsOf: page)
        hasMore = page.count >= Self.pageSize
        isLoadingMore = false
    }

    // MARK: - Empty State

    // MARK: - Custom Date Range Popover

    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("自定义日期范围", "Custom Date Range"))
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                DatePicker(L("从", "From"), selection: $customRangeStart, displayedComponents: .date)
                DatePicker(L("到", "To"), selection: $customRangeEnd, displayedComponents: .date)
            }
            .font(.system(size: 12))

            HStack {
                Spacer()
                Button {
                    showCustomRange = false
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsControl)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    dateFilter = .custom(from: customRangeStart, to: customRangeEnd)
                    showCustomRange = false
                } label: {
                    Text(L("应用", "Apply"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsText)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(TF.settingsTextTertiary)
            Text(L("还没有识别记录", "No records yet"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Text(L("使用快捷键开始语音输入后\n记录会出现在这里", "Records will appear here after\nyou use a hotkey to start voice input"))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Date Section Header

    private func sectionHeaderView(_ section: DateSection) -> some View {
        let totalDuration = section.records.reduce(0.0) { $0 + $1.durationSeconds }
        let count = section.records.count
        return HStack(spacing: 4) {
            Text(section.group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary.opacity(0.4))
            Text(L("\(count) 条", "\(count) rec"))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary.opacity(0.4))
            Text(formatDuration(totalDuration))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Export Popover

    private var exportPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("导出识别记录", "Export Records"))
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: $exportRangeAll) {
                Text(L("全部记录", "All records")).tag(true)
                Text(L("指定日期范围", "Date range")).tag(false)
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 12))

            if !exportRangeAll {
                HStack(spacing: 8) {
                    DatePicker(L("从", "From"), selection: $exportStart, displayedComponents: .date)
                    DatePicker(L("到", "To"), selection: $exportEnd, displayedComponents: .date)
                }
                .font(.system(size: 12))
            }

            Text(L("共 \(exportRecordCount) 条记录", "\(exportRecordCount) records"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    showExportPopover = false
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsControl)
                        )
                }
                .buttonStyle(.plain)

                Button(action: exportCSV) {
                    Text(L("导出 CSV", "Export CSV"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsText)
                        )
                }
                .buttonStyle(.plain)
                    .disabled(exportRecordCount == 0)
                    .opacity(exportRecordCount == 0 ? 0.4 : 1)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { refreshExportCount() }
        .onChange(of: exportRangeAll) { refreshExportCount() }
        .onChange(of: exportStart) { refreshExportCount() }
        .onChange(of: exportEnd) { refreshExportCount() }
    }

    private func refreshExportCount() {
        Task {
            let c: Int
            if exportRangeAll {
                c = await historyStore.count()
            } else {
                let startOfDay = Calendar.current.startOfDay(for: exportStart)
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: exportEnd)) ?? exportEnd
                c = await historyStore.count(from: startOfDay, to: endOfDay)
            }
            await MainActor.run { exportRecordCount = c }
        }
    }

    private func exportCSV() {
        // Fetch all records from DB for export (bypass page limit)
        Task {
            let allRecords = await historyStore.fetchAll()
            await MainActor.run { doExport(allRecords) }
        }
    }

    private func doExport(_ allRecords: [HistoryRecord]) {
        let toExport: [HistoryRecord]
        if exportRangeAll {
            toExport = allRecords
        } else {
            let startOfDay = Calendar.current.startOfDay(for: exportStart)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: exportEnd)) ?? exportEnd
            toExport = allRecords.filter { $0.createdAt >= startOfDay && $0.createdAt < endOfDay }
        }
        guard !toExport.isEmpty else { return }

        let header = L(
            "时间,时长(秒),处理模式,原始文本,最终文本,用户修改后（本地观察）,观察状态,编辑数据格式版本",
            "Time,Duration(s),Mode,Raw Text,Final Text,After User Edits (Locally Observed),Observation Status,Edit Data Format Version"
        )
        let dateFormatter = ISO8601DateFormatter()
        let rows = toExport.map { r in
            let time = dateFormatter.string(from: r.createdAt)
            let duration = String(format: "%.1f", r.durationSeconds)
            let mode = r.processingMode ?? ""
            return [
                time,
                duration,
                mode,
                r.rawText,
                r.finalText,
                r.userEditedText ?? "",
                r.userEditStatus?.rawValue ?? "",
                r.userEditVersion.map(String.init) ?? "",
            ]
                .map { csvEscape($0) }
                .joined(separator: ",")
        }
        let csv = ([header] + rows).joined(separator: "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "type4me-history.csv"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            showExportPopover = false
        } catch {
            NSLog("[HistoryTab] Export failed: %@", error.localizedDescription)
        }
    }

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: - Record Card

    private func historySectionRow(
        _ record: HistoryRecord,
        index: Int,
        count: Int
    ) -> some View {
        let isFirst = index == 0
        let isLast = index == count - 1
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 14 : 0,
            bottomLeadingRadius: isLast ? 14 : 0,
            bottomTrailingRadius: isLast ? 14 : 0,
            topTrailingRadius: isFirst ? 14 : 0,
            style: .continuous
        )

        return historyRecordRow(record)
            .background(TF.settingsCard)
            .clipShape(shape)
            .overlay {
                shape.stroke(TF.settingsBorder, lineWidth: 0.5)
            }
    }

    private func historyRecordRow(_ record: HistoryRecord) -> some View {
        let isExpanded = expandedRecordIds.contains(record.id)
        let isSelected = selectedIds.contains(record.id)

        return HistoryHoverSurface(
            isSelectionMode: isSelectionMode,
            controls: { isHovered in
                historyRecordTrailingControls(record, isHovered: isHovered, isExpanded: isExpanded)
            },
            content: {
                HStack(alignment: .top, spacing: 12) {
                    if isSelectionMode {
                        Toggle("", isOn: Binding(
                            get: { isSelected },
                            set: { newValue in
                                if newValue != isSelected { toggleSelection(for: record.id) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .padding(.top, 2)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.createdAt.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(TF.settingsTextSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(String(format: "%.1fs", record.durationSeconds))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .monospacedDigit()
                    }
                    .frame(width: 62, alignment: .leading)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(record.finalText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 10) {
                            if let chars = record.characterCount {
                                Label(L("\(chars) 字", "\(chars) chars"), systemImage: "doc.text")
                            }
                            if let mode = record.processingMode {
                                Label(mode, systemImage: "text.bubble")
                            } else {
                                Label(L("直接转写", "Transcription"), systemImage: "waveform")
                            }
                            if let vendor = historyASRVendorDescription(record) {
                                Label(vendor, systemImage: "mic")
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)

                        if isExpanded {
                            expandedRecordDetails(record)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Reserve a stable action area so hovering never causes the
                    // text to reflow while the user is scrolling.
                    .padding(.trailing, isSelectionMode ? 0 : 88)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                toggleSelection(for: record.id)
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedRecordIds.remove(record.id)
                    } else {
                        expandedRecordIds.insert(record.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRecordTrailingControls(
        _ record: HistoryRecord,
        isHovered: Bool,
        isExpanded: Bool
    ) -> some View {
        if isHovered || copiedId == record.id {
            HStack(spacing: 5) {
                historyRecordAction(
                    icon: "character.textbox",
                    tooltip: L("纠错", "Correct")
                ) {
                    correctionRecord = record
                }

                historyRecordAction(
                    icon: copiedId == record.id ? "checkmark" : "doc.on.doc",
                    tooltip: copiedId == record.id ? L("已复制", "Copied") : L("复制", "Copy"),
                    color: copiedId == record.id ? TF.settingsAccentGreen : TF.settingsTextSecondary
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.finalText, forType: .string)
                    copiedId = record.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedId == record.id { copiedId = nil }
                    }
                }

                historyRecordAction(
                    icon: "trash",
                    tooltip: L("删除", "Delete"),
                    color: TF.settingsAccentRed.opacity(0.8)
                ) {
                    Task {
                        await historyStore.delete(id: record.id)
                        records.removeAll { $0.id == record.id }
                    }
                }
            }
            .padding(.leading, 8)
            .background(
                Rectangle()
                    .fill(TF.settingsRowHover)
            )
            .transition(.opacity)
        } else {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TF.settingsTextTertiary.opacity(0.65))
                .frame(width: 20, height: 26)
        }
    }

    private func expandedRecordDetails(_ record: HistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(TF.settingsBorder)

            if !record.rawText.isEmpty && record.rawText != record.finalText {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("原始文本", "Original text"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(record.rawText)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .textSelection(.enabled)
                }
            }

            if let trace = decodeIntelliSenseTrace(record.intelliSenseTraceJSON) {
                intelliSenseTraceDetails(trace)
            }

            if let userEditedText = record.userEditedText {
                VStack(alignment: .leading, spacing: 6) {
                    historyTextDetail(
                        title: L("Type4Me 输出", "Type4Me output"),
                        text: record.finalText
                    )
                    historyTextDetail(
                        title: L("用户修改后", "After user edits"),
                        text: userEditedText
                    )
                    if record.userEditStatus == .clearedAfterEdit {
                        Text(L("输入区域随后被清空", "The input area was cleared afterward"))
                            .font(.system(size: 9))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                }
            } else if record.userEditStatus == .sensitiveRedacted {
                Text(L("修改结果未保存", "Edited text was not saved"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            HStack(spacing: 12) {
                if let asr = historyASRDescription(record) {
                    Label(asr, systemImage: "mic")
                }
                if let llm = historyLLMDescription(record) {
                    Label(llm, systemImage: "cpu")
                }
                if !record.status.isEmpty {
                    Label(record.status, systemImage: "checkmark.circle")
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(TF.settingsTextTertiary)
        }
    }

    private func historyTextDetail(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextSecondary)
                .textSelection(.enabled)
        }
    }

    private func historyASRDescription(_ record: HistoryRecord) -> String? {
        let model = record.asrModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = record.asrProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = model?.isEmpty == false ? model : (provider?.isEmpty == false ? provider : nil)
        return historySourceDescription(source, durationSeconds: record.asrDurationSeconds)
    }

    private func historyASRVendorDescription(_ record: HistoryRecord) -> String? {
        let model = record.asrModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = record.asrProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = model?.isEmpty == false ? model : provider
        return source?
            .components(separatedBy: " · ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func historyLLMDescription(_ record: HistoryRecord) -> String? {
        let rawProvider = record.llmProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = record.llmModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawProvider?.isEmpty == false || model?.isEmpty == false else { return nil }

        let providerName: String? = {
            guard let rawProvider, !rawProvider.isEmpty else { return nil }
            if rawProvider == "cloud" { return L("Type4Me 云端", "Type4Me Cloud") }
            return LLMProvider(rawValue: rawProvider)?.displayName ?? rawProvider
        }()

        let source: String?
        if let model, !model.isEmpty, model != "cloud" {
            source = providerName.map { "\($0) · \(model)" } ?? model
        } else {
            source = providerName
        }
        return historySourceDescription(source, durationSeconds: record.llmDurationSeconds)
    }

    private func historySourceDescription(_ source: String?, durationSeconds: Double?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        guard let durationSeconds, durationSeconds >= 0, durationSeconds.isFinite else { return source }
        return "\(source) · \(String(format: "%.1fs", durationSeconds))"
    }

    @ViewBuilder
    private func intelliSenseTraceDetails(_ trace: IntelliSenseHistoryTrace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("智能感知说明", "Intelli Sense Details"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)

            intelliSenseTraceRow(
                label: L("感知环境", "Environment"),
                value: intelliSenseEnvironmentDescription(trace)
            )
            intelliSenseTraceRow(
                label: L("处理依据", "Signals used"),
                value: intelliSenseBasisDescription(trace)
            )
            intelliSenseTraceRow(
                label: L("处理结果", "Adjustments"),
                value: trace.effects.prefix(3).map(intelliSenseEffectDescription).joined(separator: " · ")
            )
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TF.settingsControl.opacity(0.72))
        )
    }

    private func intelliSenseTraceRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func decodeIntelliSenseTrace(_ json: String?) -> IntelliSenseHistoryTrace? {
        guard let json, let data = json.data(using: .utf8),
              let trace = try? JSONDecoder().decode(IntelliSenseHistoryTrace.self, from: data),
              trace.version <= IntelliSenseHistoryTrace.currentVersion else { return nil }
        return trace
    }

    private func intelliSenseEnvironmentDescription(_ trace: IntelliSenseHistoryTrace) -> String {
        let app = trace.appName ?? intelliSenseAppCategoryDescription(trace.appCategory)
        let control = intelliSenseControlDescription(trace.controlCategory)
        return control.isEmpty ? app : "\(app) · \(control)"
    }

    private func intelliSenseBasisDescription(_ trace: IntelliSenseHistoryTrace) -> String {
        if trace.effects.contains(.processingFallback) {
            return L("处理未完成，未应用增强感知", "Processing did not complete; enhanced awareness was not applied")
        }
        switch trace.contextAvailability {
        case .blacklisted:
            return L("该应用已禁用感知，仅执行基础润色", "Awareness is disabled for this app; only basic polish was used")
        case .sensitive:
            return L("检测到敏感输入区域，仅执行基础润色", "A sensitive input area was detected; only basic polish was used")
        default:
            break
        }

        var values: [String] = []
        if trace.appliedLayers.contains(.application) {
            values.append(L("当前应用和输入框", "current app and input field"))
        }
        if trace.enabledLayers.contains(.context) {
            values.append(trace.appliedLayers.contains(.context)
                ? L("光标附近文字", "nearby text")
                : L("没有可用的上下文", "no usable context"))
        }
        if trace.enabledLayers.contains(.expression) {
            values.append(trace.appliedLayers.contains(.expression)
                ? L("稳定表达习惯", "stable expression habits")
                : L("没有已生效的表达习惯", "no active expression habits"))
        }
        return values.isEmpty
            ? L("仅执行基础润色", "basic polish only")
            : values.joined(separator: " · ")
    }

    private func intelliSenseAppCategoryDescription(_ category: ApplicationCategory) -> String {
        switch category {
        case .messaging: return L("聊天应用", "Messaging app")
        case .email: return L("邮件应用", "Email app")
        case .document: return L("文档应用", "Document app")
        case .browser: return L("浏览器", "Browser")
        case .development: return L("开发工具", "Development tool")
        case .terminal: return L("终端", "Terminal")
        case .other: return L("未知应用", "Unknown app")
        }
    }

    private func intelliSenseControlDescription(_ control: InputControlCategory) -> String {
        switch control {
        case .singleLine: return L("单行输入框", "Single-line field")
        case .multiLine: return L("正文输入框", "Body field")
        case .search: return L("搜索框", "Search field")
        case .title: return L("标题输入框", "Title field")
        case .code: return L("代码输入区", "Code field")
        case .terminal: return L("终端输入区", "Terminal field")
        case .unknown: return ""
        }
    }

    private func intelliSenseEffectDescription(_ effect: IntelliSenseHistoryEffect) -> String {
        switch effect {
        case .searchQueryCompressed: return L("转为搜索关键词", "Converted to search terms")
        case .titleCompacted: return L("整理为简洁标题", "Compacted into a title")
        case .chatToneAdapted: return L("调整为自然短句", "Adapted to a natural short message")
        case .emailToneAdapted: return L("调整为完整礼貌表达", "Adapted to complete, polite wording")
        case .documentStructured: return L("整理段落或结构", "Organized paragraph structure")
        case .listStructured: return L("按多要点列表整理", "Structured as a multi-point list")
        case .technicalSyntaxPreserved: return L("保留技术语法和标识符", "Preserved technical syntax and identifiers")
        case .explicitCorrectionApplied: return L("采用最终改口内容", "Applied the final self-correction")
        case .contextTermAdopted: return L("沿用上下文中的术语写法", "Adopted terminology from nearby text")
        case .fillerRemoved: return L("删除口语填充词", "Removed speech fillers")
        case .formattingAdjusted: return L("规范标点和格式", "Normalized punctuation and formatting")
        case .generalPolish: return L("进行自适应轻度润色", "Applied adaptive light polish")
        case .noSignificantRewrite: return L("原文已适合当前场景，未明显改写", "The original already fit the scene; no significant rewrite")
        case .protectedResultFallback: return L("候选结果触发保护，已保留更忠实的原文", "The candidate triggered protection; the more faithful original was kept")
        case .processingFallback: return L("智能处理不可用，已使用回退结果", "Intelligent processing was unavailable; a fallback result was used")
        }
    }

    private func historyRecordAction(
        icon: String,
        tooltip: String,
        color: Color = TF.settingsTextSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HistoryFloatingTooltipController.shared.hide()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(TF.settingsControl)
                )
        }
        .buttonStyle(.plain)
        .historyFloatingTooltip(tooltip)
    }

    // MARK: - Statistics UI

    private func statisticsSection(stats: HistoryStore.Statistics) -> some View {
        HStack(spacing: 0) {
            historyMetric(
                icon: "clock",
                label: L("累计时长", "Total Time"),
                value: formatDuration(stats.totalDuration),
                showsDetails: true
            )

            historyMetricDivider

            historyMetric(
                icon: "doc.text",
                label: L("累计字数", "Total Chars"),
                value: formatNumber(stats.totalCharacters)
            )

            historyMetricDivider

            historyMetric(
                icon: "bolt",
                label: L("平均速度", "Avg Speed"),
                value: String(format: L("%.0f 字/分", "%.0f ch/min"), stats.averageSpeed)
            )
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TF.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }

    private func historyMetric(
        icon: String,
        label: String,
        value: String,
        showsDetails: Bool = false
    ) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsControl)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(label)
                    if showsDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)

                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .monospacedDigit()
            }

            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        return Group {
            if showsDetails {
                Button {
                    showUsageDetails = true
                    Task { await loadUsageBreakdown() }
                } label: {
                    content
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsTooltip(L("查看用量详情", "View usage details"), isEnabled: !showUsageDetails)
                .popover(isPresented: $showUsageDetails, arrowEdge: .bottom) {
                    usageDetailsPopover
                        .task { await loadUsageBreakdown() }
                }
            } else {
                content
            }
        }
    }

    private var historyMetricDivider: some View {
        Rectangle()
            .fill(TF.settingsBorder)
            .frame(width: 1, height: 40)
    }

    private var usageDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(TF.settingsControl)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("本机用量详情", "Local usage details"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                    Text(L("按识别历史中的模型/引擎估算，删除历史会同步影响统计。", "Estimated from recognition history by model/engine. Deleting history updates these totals."))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            if usageBreakdownLoading && usageBreakdown.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("正在读取用量...", "Loading usage..."))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 92)
            } else if usageBreakdown.isEmpty {
                Text(L("还没有可统计的识别记录", "No recognition history to summarize yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, minHeight: 92)
            } else {
                VStack(spacing: 0) {
                    usageDetailsHeader

                    ForEach(usageBreakdown) { row in
                        usageDetailsRow(row)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TF.settingsTextTertiary.opacity(0.16), lineWidth: 1)
                )
            }
        }
        .padding(16)
        .frame(width: 550)
    }

    private var usageDetailsHeader: some View {
        HStack(spacing: 10) {
            Text(L("模型 / 引擎", "Model / Engine"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("近1天", "1 day"))
                .frame(width: 78, alignment: .trailing)
            Text(L("7天", "7 days"))
                .frame(width: 78, alignment: .trailing)
            Text(L("30天", "30 days"))
                .frame(width: 78, alignment: .trailing)
            Text(L("全部", "All time"))
                .frame(width: 78, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(TF.settingsTextTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TF.settingsControl)
    }

    private func usageDetailsRow(_ row: HistoryStore.UsageBreakdown) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatUsageDuration(row.lastDayDuration))
                .frame(width: 78, alignment: .trailing)
            Text(formatUsageDuration(row.last7DaysDuration))
                .frame(width: 78, alignment: .trailing)
            Text(formatUsageDuration(row.last30DaysDuration))
                .frame(width: 78, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatUsageDuration(row.allTimeDuration))
                Text(L("\(row.recordCount) 条记录", "\(row.recordCount) records"))
                    .font(.system(size: 9))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .frame(width: 78, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(TF.settingsText)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TF.settingsCard)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TF.settingsTextTertiary.opacity(0.10))
                .frame(height: 1)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(format: L("%d小时%d分", "%dh %dm"), hours, minutes)
        } else if minutes > 0 {
            return String(format: L("%d分钟", "%dm"), minutes)
        } else {
            return String(format: L("%d秒", "%ds"), totalSeconds)
        }
    }

    private func formatUsageDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total == 0 { return "0s" }

        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLanguage.current == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
