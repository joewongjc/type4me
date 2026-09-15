import SwiftUI

/// Predefined time ranges for usage analytics filtering.
public enum AnalyticsTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case last7Days
    case last30Days
    case all

    public var id: String { rawValue }

    public var localizedDisplayName: String {
        switch self {
        case .today:     return L("今天", "Today")
        case .last7Days: return L("近 7 天", "Last 7 Days")
        case .last30Days:return L("近 30 天", "Last 30 Days")
        case .all:       return L("全部", "All Time")
        }
    }

    public var startDate: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .all:
            return nil
        }
    }
}

/// Standalone dashboard for speech engine (ASR) metrics, migrated out of HistoryTab's drawer.
public struct ASRUsageAnalyticsView: View {
    @State private var selectedRange: AnalyticsTimeRange = .last7Days
    @State private var statistics: HistoryStore.Statistics?
    @State private var usageBreakdown: [HistoryStore.UsageBreakdown] = []
    @State private var isLoading = false

    private let historyStore = HistoryStore.shared

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // Header with Time Range Picker
                HStack {
                    Text(L("语音引擎用量看板", "Speech Engines Analytics"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TF.settingsText)

                    Spacer()

                    timeRangePicker
                }
                .padding(.bottom, 2)

                // KPI Summary Section
                if let stats = statistics {
                    kpiSection(stats: stats)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }

                // Engine Breakdown Table
                breakdownSection
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 24)
        }
        .task(id: selectedRange) {
            await loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            Task { await loadData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyFeedbackDidChange)) { _ in
            Task { await loadData() }
        }
    }

    // MARK: - Time Range Picker

    private var timeRangePicker: some View {
        LiquidGlassTabPicker(
            items: AnalyticsTimeRange.allCases,
            selection: selectedRange,
            spacing: 2,
            onSelectionChange: { newRange in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    selectedRange = newRange
                }
            }
        ) { range, isSelected, _ in
            Text(range.localizedDisplayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
        }
        .fixedSize()
    }

    // MARK: - KPI Section

    private func kpiSection(stats: HistoryStore.Statistics) -> some View {
        HStack(spacing: 0) {
            historyMetric(
                icon: "clock",
                label: L("录音时长", "Audio Duration"),
                value: formatDuration(stats.totalDuration)
            )

            historyMetricDivider

            historyMetric(
                icon: "doc.text",
                label: L("识别字数", "Total Chars"),
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
        value: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsControl)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
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
    }

    private var historyMetricDivider: some View {
        Rectangle()
            .fill(TF.settingsBorder)
            .frame(width: 1, height: 40)
    }

    // MARK: - Breakdown Table

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("引擎 / 模型明细", "Engine / Model Breakdown"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TF.settingsText)

            VStack(spacing: 0) {
                // Table Header
                HStack(spacing: 10) {
                    Text(L("引擎 / 模型", "Engine / Model"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("24小时", "24h"))
                        .frame(width: 70, alignment: .trailing)
                    Text(L("7天", "7d"))
                        .frame(width: 70, alignment: .trailing)
                    Text(L("30天", "30d"))
                        .frame(width: 70, alignment: .trailing)
                    Text(L("全部", "All"))
                        .frame(width: 80, alignment: .trailing)
                    Text(L("差评率", "Bad %"))
                        .frame(width: 68, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TF.settingsControl)

                Divider()

                if usageBreakdown.isEmpty {
                    Text(L("暂无引擎使用记录", "No engine usage records"))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else {
                    VStack(spacing: 0) {
                        ForEach(usageBreakdown) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.modelName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(TF.settingsText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(formatUsageDuration(row.lastDayDuration))
                                    .frame(width: 70, alignment: .trailing)
                                Text(formatUsageDuration(row.last7DaysDuration))
                                    .frame(width: 70, alignment: .trailing)
                                Text(formatUsageDuration(row.last30DaysDuration))
                                    .frame(width: 70, alignment: .trailing)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatUsageDuration(row.allTimeDuration))
                                    Text(String(format: L("%d条", "%d recs"), row.recordCount))
                                        .font(.system(size: 9))
                                        .foregroundStyle(TF.settingsTextTertiary)
                                }
                                .frame(width: 80, alignment: .trailing)

                                HStack(spacing: 2) {
                                    if row.badCount > 0 {
                                        Text("\(row.badCount)")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.red)
                                    }
                                    Text(formatBadPercentage(row.badPercentage))
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(row.badCount > 0 ? .red : TF.settingsTextSecondary)
                                }
                                .frame(width: 68, alignment: .trailing)
                            }
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(TF.settingsText)
                            .monospacedDigit()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) {
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(TF.settingsCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TF.settingsBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        let iso = ISO8601DateFormatter()
        let fromDate = selectedRange.startDate
        let fromStr = fromDate.map { iso.string(from: $0) }
        async let statsFetch = historyStore.getStatistics(from: fromStr, to: nil)
        async let breakdownFetch = historyStore.getFilteredUsageBreakdown(from: fromDate, to: nil)

        let (stats, breakdown) = await (statsFetch, breakdownFetch)
        self.statistics = stats
        self.usageBreakdown = breakdown
    }

    // MARK: - Formatters

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: L("%d小时%d分", "%dh %dm"), hours, minutes)
        }
        return String(format: L("%d分%d秒", "%dm %ds"), minutes, secs)
    }

    private func formatUsageDuration(_ seconds: Double) -> String {
        if seconds <= 0 { return "-" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: L("%d小时%d分", "%dh %dm"), hours, minutes)
        }
        if minutes > 0 {
            return String(format: L("%d分%d秒", "%dm %ds"), minutes, secs)
        }
        return String(format: L("%d秒", "%ds"), secs)
    }

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }

    private func formatBadPercentage(_ val: Double) -> String {
        if val <= 0 { return "-" }
        return String(format: "%.1f%%", val * 100)
    }
}
