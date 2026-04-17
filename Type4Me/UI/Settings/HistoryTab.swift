import SwiftUI

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

// MARK: - View

struct HistoryTab: View {

    let isActive: Bool

    private let historyStore = HistoryStore()

    @State private var records: [HistoryRecord] = []
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var searchText = ""
    @State private var copiedId: String?
    @State private var statistics: HistoryStore.Statistics?

    private static let pageSize = 50

    /// Fixed height for every control in the top toolbar row (search field
    /// + date filter + selection + export). Locking all items to the same
    /// height keeps type baselines aligned and prevents the buttons from
    /// looking smaller than the search box.
    private let toolbarHeight: CGFloat = 30

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

    private var filtered: [HistoryRecord] {
        if searchText.isEmpty { return records }
        return records.filter {
            $0.finalText.localizedCaseInsensitiveContains(searchText)
            || $0.rawText.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// True when every row in the current list (loaded + search filter) is selected.
    private var isAllFilteredSelected: Bool {
        HistorySelectionHelpers.isAllFilteredSelected(
            filteredIds: Set(filtered.map(\.id)),
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

    private var groupedRecords: [(DayGroup, [HistoryRecord])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { DayGroup(date: cal.startOfDay(for: $0.createdAt)) }
        return grouped.map { ($0.key, $0.value) }
            .sorted { $0.0.date > $1.0.date }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "HISTORY",
                title: L("识别历史", "History"),
                description: L("浏览和管理语音识别记录。", "Browse and manage speech recognition records.")
            )

            // Statistics Section
            if let stats = statistics, stats.recordCount > 0 {
                statisticsSection(stats: stats)
                    .padding(.bottom, TF.spacingMD)
            }

            // Search + date filter + selection + export.
            //
            // Visual baseline: every control in this row locks to
            // `toolbarHeight` (30pt) and uses 12pt type so the search
            // baseline and the button baselines sit on a single line. The
            // previous layout mixed 12pt/11pt and 7pt/6pt vertical padding,
            // which made button text read "smaller and floating" next to
            // the search box.
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                    TextField(L("搜索记录...", "Search..."), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: toolbarHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )

                // Date filter menu
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
                        Image(systemName: "calendar").font(.system(size: 11))
                        Text(dateFilter.label).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(dateFilter == .all ? TF.settingsTextSecondary : TF.settingsNavActive)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: toolbarHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(dateFilter == .all
                            ? TF.settingsTextTertiary.opacity(0.2)
                            : TF.settingsNavActive.opacity(0.4),
                        lineWidth: 1)
                )
                .popover(isPresented: $showCustomRange, arrowEdge: .bottom) {
                    customRangePopover
                }

                Button {
                    if isSelectionMode {
                        isSelectionMode = false
                        selectedIds.removeAll()
                    } else {
                        isSelectionMode = true
                    }
                } label: {
                    Text(isSelectionMode ? L("完成", "Done") : L("选择", "Select"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: toolbarHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )
                .disabled(records.isEmpty)

                Button {
                    showExportPopover = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11))
                        Text(L("导出", "Export")).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(TF.settingsTextSecondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: toolbarHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )
                .disabled(records.isEmpty || isSelectionMode)
                .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
                    exportPopover
                }
            }
            .padding(.bottom, isSelectionMode ? 8 : 12)

            if isSelectionMode && !records.isEmpty {
                batchSelectionBar
                    .padding(.bottom, 12)
            }

            if records.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text(L("没有匹配的记录", "No matching records"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(groupedRecords, id: \.0) { group, groupRecords in
                            dateSectionView(group, records: groupRecords)
                        }

                        if hasMore && searchText.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .id("load-more-\(records.count)")
                                .onAppear {
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
        HStack(spacing: 12) {
            Text(L("已选 \(selectedIds.count) 条", "\(selectedIds.count) selected"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)

            Spacer()

            Button {
                selectedIds = HistorySelectionHelpers.togglingSelectAllInFiltered(
                    filteredIds: Set(filtered.map(\.id)),
                    selectedIds: selectedIds
                )
            } label: {
                Text(
                    isAllFilteredSelected
                        ? L("取消全选", "Deselect All")
                        : L("全选当前列表", "Select All in List")
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TF.settingsNavActive)
            .disabled(filtered.isEmpty)

            Button {
                showBatchDeleteConfirm = true
            } label: {
                Text(L("删除", "Delete"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TF.settingsAccentRed)
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TF.settingsBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
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
                Button(L("取消", "Cancel")) { showCustomRange = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(L("应用", "Apply")) {
                    dateFilter = .custom(from: customRangeStart, to: customRangeEnd)
                    showCustomRange = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsNavActive))
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

    // MARK: - Date Section

    private func dateSectionView(_ group: DayGroup, records: [HistoryRecord]) -> some View {
        let totalDuration = records.reduce(0.0) { $0 + $1.durationSeconds }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.4))
                Text(L("\(records.count) 条", "\(records.count)"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.4))
                Text(formatDuration(totalDuration))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
            }

            ForEach(records) { record in
                recordCard(
                    record,
                    showDate: false,
                    isSelectionMode: isSelectionMode,
                    isSelected: selectedIds.contains(record.id),
                    onToggleSelection: { toggleSelection(for: record.id) }
                )
            }
        }
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
                Button(L("取消", "Cancel")) { showExportPopover = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(L("导出 CSV", "Export CSV")) { exportCSV() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsNavActive))
                    .disabled(exportRecordCount == 0)
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

        let header = L("时间,时长(秒),处理模式,原始文本,最终文本", "Time,Duration(s),Mode,Raw Text,Final Text")
        let dateFormatter = ISO8601DateFormatter()
        let rows = toExport.map { r in
            let time = dateFormatter.string(from: r.createdAt)
            let duration = String(format: "%.1f", r.durationSeconds)
            let mode = r.processingMode ?? ""
            return [time, duration, mode, r.rawText, r.finalText]
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

    private func recordCard(
        _ record: HistoryRecord,
        showDate: Bool,
        isSelectionMode: Bool,
        isSelected: Bool,
        onToggleSelection: @escaping () -> Void
    ) -> some View {
        let metadataAndText = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                let timeFormat: Date.FormatStyle = showDate
                    ? .dateTime.month().day().hour().minute()
                    : .dateTime.hour().minute()
                Label(record.createdAt.formatted(timeFormat), systemImage: "clock")
                Label(String(format: "%.1fs", record.durationSeconds), systemImage: "waveform")
                if let chars = record.characterCount {
                    Label(L("\(chars) 字", "\(chars) chars"), systemImage: "doc.text")
                }
                if let mode = record.processingMode {
                    Label(mode, systemImage: "text.bubble")
                }
                if let provider = record.asrProvider {
                    Label(provider, systemImage: "mic")
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(TF.settingsTextTertiary)

            Text(record.finalText)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if record.processedText != nil {
                HStack(alignment: .top, spacing: 4) {
                    Text(L("原始:", "Raw:"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(record.rawText)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .textSelection(.enabled)
                }
            }

            if !isSelectionMode {
                HStack(spacing: 8) {
                    Spacer()

                    Button {
                        correctionRecord = record
                    } label: {
                        Label(L("纠错", "Correct"), systemImage: "character.textbox")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsAccentAmber)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.finalText, forType: .string)
                        copiedId = record.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedId == record.id { copiedId = nil }
                        }
                    } label: {
                        Label(
                            copiedId == record.id ? L("已复制", "Copied") : L("复制", "Copy"),
                            systemImage: copiedId == record.id ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copiedId == record.id ? TF.settingsAccentGreen : TF.settingsTextSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await historyStore.delete(id: record.id)
                            records.removeAll { $0.id == record.id }
                        }
                    } label: {
                        Label(L("删除", "Delete"), systemImage: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsAccentRed.opacity(0.7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        return Group {
            if isSelectionMode {
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { isSelected },
                        set: { new in
                            if new != isSelected { onToggleSelection() }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    metadataAndText
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onToggleSelection() }
                }
            } else {
                metadataAndText
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg)
        )
    }

    // MARK: - Statistics UI

    private func statisticsSection(stats: HistoryStore.Statistics) -> some View {
        HStack(spacing: TF.spacingMD) {
            statCard(
                icon: "clock.fill",
                label: L("累计时长", "Total Time"),
                value: formatDuration(stats.totalDuration),
                color: TF.settingsAccentAmber
            )

            statCard(
                icon: "doc.text",
                label: L("累计字数", "Total Chars"),
                value: formatNumber(stats.totalCharacters),
                color: TF.settingsAccentGreen
            )

            statCard(
                icon: "speedometer",
                label: L("平均速度", "Avg Speed"),
                value: String(format: L("%.0f 字/分", "%.0f ch/min"), stats.averageSpeed),
                color: TF.settingsText
            )
        }
    }

    private func statCard(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TF.spacingSM)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TF.cornerSM)
                .fill(TF.settingsBg)
        )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return String(format: L("%d小时%d分", "%dh %dm"), hours, minutes)
        } else {
            return String(format: L("%d分钟", "%dm"), minutes)
        }
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLanguage.current == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
