import SwiftUI
import Charts

/// Standalone dashboard for LLM analytics, token volume, estimated costs, and feature breakdowns.
public struct LLMUsageAnalyticsView: View {
    @State private var selectedRange: AnalyticsTimeRange = .last7Days
    @State private var report: HistoryStore.LLMUsageReport = .init()
    @State private var dailyModelItems: [HistoryStore.LLMDailyModelItem] = []
    @State private var recentRecords: [LLMUsageRecord] = []
    @State private var recentTotalCount: Int = 0
    @State private var recentCurrentPage: Int = 1
    @State private var recentPageSize: Int = 20
    @State private var recentHasMore: Bool = false
    @State private var activeTab: LLMAnalyticsDisplayMode = .aggregated
    @State private var trendMetric: TrendMetric = .tokens
    @State private var isLoading = false
    @State private var pricingSync = LLMPricingSyncService.shared
    @State private var hoveredDayIdentifier: String?

    private let historyStore = HistoryStore.shared

    public enum TrendMetric: String, CaseIterable, Identifiable {
        case tokens
        case cost

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tokens: return L("按 Token 统计", "By Tokens")
            case .cost:   return L("按预估费用", "By Cost")
            }
        }
    }

    public enum LLMAnalyticsDisplayMode: String, CaseIterable, Identifiable {
        case aggregated
        case recentRequests

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .aggregated:     return L("模型与场景统计", "Aggregated Breakdown")
            case .recentRequests: return L("逐条请求明细", "Recent Invocations")
            }
        }
    }

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // Top Bar: Title & Time Range Filter
                HStack {
                    HStack(spacing: 8) {
                        Text(L("大模型用量看板", "LLM Usage & Cost Analytics"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(TF.settingsText)

                        if report.summary.hasEstimatedUsage {
                            Text(L("含部分回溯/估算数据", "Includes estimated usage"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TF.settingsTextTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(TF.settingsControl)
                                )
                        }

                        pricingStatusBadge
                    }

                    Spacer()

                    timeRangePicker
                }

                // KPI Summary Cards (Unified with Transcripts style)
                kpiSection(summary: report.summary)

                // Daily Token / Cost Consumption Trend (Charts)
                if !report.dailyTrend.isEmpty {
                    dailyTrendSection
                }

                // Section Header with Stable, Persistent Display Mode Picker
                HStack(spacing: 12) {
                    Text(activeTab == .aggregated ? L("模型用量明细", "Model Breakdown") : L("逐条请求明细", "Recent Invocations"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.settingsText)

                    displayModePicker

                    Spacer()
                }
                .padding(.top, 4)

                // Main Content Area
                if activeTab == .aggregated {
                    VStack(alignment: .leading, spacing: 14) {
                        modelBreakdownSectionContent

                        if !report.featureBreakdowns.isEmpty {
                            featureBreakdownSection
                        }
                    }
                } else {
                    recentRequestsSectionContent
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 24)
        }
        .task(id: selectedRange) {
            recentCurrentPage = 1
            await loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmPricingTableDidChange)) { _ in
            // rate(for:) is synchronous; re-render rows that were computed
            // against the previous (possibly empty) pricing table.
            Task { await loadData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmUsageStoreDidChange)) { _ in
            Task { await loadData() }
        }
    }

    // MARK: - Pricing Sync Status

    /// Header badge showing pricing table freshness plus a manual refresh control.
    private var pricingStatusBadge: some View {
        HStack(spacing: 6) {
            if pricingSync.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                if let error = pricingSync.lastSyncError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .settingsTooltip(error)
                }
                if let lastSync = pricingSync.lastSyncDate {
                    Text(L("价格更新于 \(Self.pricingRelativeTime(lastSync))", "Prices updated \(Self.pricingRelativeTime(lastSync))"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                } else {
                    Text(L("使用内置价目表", "Using built-in prices"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Button {
                    Task { await pricingSync.syncNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                .buttonStyle(.plain)
                .settingsTooltip(L("同步最新模型价格", "Sync latest model prices"))
            }
        }
    }

    /// Localized relative time ("just now" / "3 days ago") honoring the app language.
    private static func pricingRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = AppLanguage.current == .zh
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Time Range Filter

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

    // MARK: - Display Mode Picker (Liquid Glass Tab Picker)

    private var displayModePicker: some View {
        LiquidGlassTabPicker(
            items: LLMAnalyticsDisplayMode.allCases,
            selection: activeTab,
            spacing: 2,
            onSelectionChange: { newMode in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    activeTab = newMode
                }
            }
        ) { mode, isSelected, _ in
            Text(mode.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
        }
        .fixedSize()
    }
    // MARK: - KPI Section (Unified Style with HistoryTab)

    private func kpiSection(summary: HistoryStore.LLMSummaryStats) -> some View {
        HStack(spacing: 0) {
            historyMetric(
                icon: "sparkles",
                label: L("总消耗 Token", "Total Tokens"),
                value: formatTokens(summary.totalTokens),
                detail: String(format: L("入 %@ · 出 %@", "In %@ · Out %@"),
                               formatTokens(summary.totalPromptTokens),
                               formatTokens(summary.totalCompletionTokens))
            )

            historyMetricDivider

            historyMetric(
                icon: "dollarsign.circle",
                label: L("预估总成本", "Estimated Cost"),
                value: formatCostUSD(summary.totalCostUSD),
                detail: String(format: "≈ ¥%.2f", summary.totalCostUSD * LLMPricingRegistry.usdToCnyRate)
            )

            historyMetricDivider

            historyMetric(
                icon: "bolt",
                label: L("请求与耗时", "Requests & Latency"),
                value: String(format: L("%d 次", "%d reqs"), summary.totalRequests),
                detail: String(format: L("均 %.2fs · %.1f%% 成功", "Avg %.2fs · %.1f%%"),
                               summary.averageDurationSeconds,
                               summary.successRate * 100)
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
        detail: String? = nil
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
                HStack(spacing: 4) {
                    Text(label)
                    if let detail {
                        Text("(\(detail))")
                            .font(.system(size: 9))
                            .foregroundStyle(TF.settingsTextTertiary)
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
    }

    private var historyMetricDivider: some View {
        Rectangle()
            .fill(TF.settingsBorder)
            .frame(width: 1, height: 40)
    }

    // MARK: - Daily Usage Trend

    private var dailyTrendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("每日消耗趋势", "Daily Usage Trend"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                // Metric Toggle (Tokens vs Cost) via LiquidGlassTabPicker
                LiquidGlassTabPicker(
                    items: TrendMetric.allCases,
                    selection: trendMetric,
                    spacing: 2,
                    onSelectionChange: { newMetric in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            trendMetric = newMetric
                        }
                    }
                ) { metric, isSelected, _ in
                    Text(metric.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                }
                .fixedSize()
                Spacer()

                // Detailed Hover Preview (Models & Breakdown)
                if let dayId = hoveredDayIdentifier {
                    let matchingItems = dailyModelItems.filter { $0.dayIdentifier == dayId }
                    HStack(spacing: 6) {
                        Text(dayId)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(TF.settingsText)

                        ForEach(matchingItems) { item in
                            HStack(spacing: 2) {
                                Text(item.model)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(TF.settingsNavActive)
                                Text(trendMetric == .tokens ? formatTokens(item.totalTokens) : formatCostUSD(item.costUSD))
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(TF.settingsTextSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(TF.settingsControl))
                }
            }

            Chart {
                ForEach(dailyModelItems) { item in
                    BarMark(
                        x: .value("Day", item.dayIdentifier),
                        y: .value(trendMetric == .tokens ? "Tokens" : "Cost",
                                  trendMetric == .tokens ? Double(item.totalTokens) : item.costUSD)
                    )
                    .foregroundStyle(by: .value("Model", item.model))
                }
            }
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    if let dVal = value.as(Double.self) {
                        AxisValueLabel {
                            Text(trendMetric == .tokens ? formatTokens(Int(dVal)) : formatCostUSD(dVal))
                                .font(.system(size: 9))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                let uniqueDays = Array(Set(dailyModelItems.map(\.dayIdentifier))).sorted()
                let strideInterval = uniqueDays.count > 25 ? max(1, uniqueDays.count / 7) : (uniqueDays.count > 12 ? 2 : 1)
                let sampledDays = uniqueDays.enumerated().compactMap { idx, day in
                    (idx % strideInterval == 0 || idx == uniqueDays.count - 1) ? day : nil
                }

                AxisMarks(values: sampledDays) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            let parts = str.split(separator: "-")
                            if parts.count == 3 {
                                let m = Int(parts[1]) ?? 0
                                let d = Int(parts[2]) ?? 0
                                Text("\(m)/\(d)")
                                    .font(.system(size: 9, design: .rounded))
                                    .monospacedDigit()
                            } else {
                                Text(String(str.suffix(5)))
                                    .font(.system(size: 9, design: .rounded))
                            }
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let plotX = location.x - geo[proxy.plotFrame!].origin.x
                                if let dayStr: String = proxy.value(atX: plotX) {
                                    hoveredDayIdentifier = dayStr
                                }
                            case .ended:
                                hoveredDayIdentifier = nil
                            }
                        }
                }
            }
            .frame(height: 120)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TF.settingsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TF.settingsBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Model Breakdown

    private var modelBreakdownSectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                // Table Header
                HStack(spacing: 10) {
                    Text(L("模型 / 厂商", "Model / Provider"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("调用次数", "Requests"))
                        .frame(width: 75, alignment: .trailing)
                    Text(L("输入 Token", "Prompt"))
                        .frame(width: 75, alignment: .trailing)
                    Text(L("输出 Token", "Completion"))
                        .frame(width: 75, alignment: .trailing)
                    Text(L("平均耗时", "Latency"))
                        .frame(width: 65, alignment: .trailing)
                    Text(L("预估成本", "Cost"))
                        .frame(width: 75, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TF.settingsControl)

                Divider()

                if report.modelBreakdowns.isEmpty {
                    Text(L("暂无大模型使用记录", "No LLM usage records"))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(report.modelBreakdowns) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.modelName)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(TF.settingsText)
                                        .lineLimit(1)
                                    Text(row.provider)
                                        .font(.system(size: 9))
                                        .foregroundStyle(TF.settingsTextTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(row.requestCount)")
                                    if row.failedCount > 0 {
                                        Text(String(format: L("%d 失败", "%d fail"), row.failedCount))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.red)
                                    }
                                }
                                .frame(width: 75, alignment: .trailing)

                                Text(formatTokens(row.promptTokens))
                                    .frame(width: 75, alignment: .trailing)
                                Text(formatTokens(row.completionTokens))
                                    .frame(width: 75, alignment: .trailing)
                                Text(String(format: "%.2fs", row.averageDurationSeconds))
                                    .frame(width: 65, alignment: .trailing)

                                HStack {
                                    if row.priceSource == .free {
                                        Text(L("免费", "Free"))
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.green.opacity(0.12)))
                                    } else if row.priceSource == .unknown {
                                        Text("—")
                                            .foregroundStyle(TF.settingsTextTertiary)
                                            .settingsTooltip(L("该模型暂未收录费率，仅统计 Token", "Rate not in catalog; tokens only"))
                                    } else {
                                        Text(formatCostUSD(row.costUSD))
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                    }
                                }
                                .frame(width: 75, alignment: .trailing)
                            }
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(TF.settingsText)
                            .monospacedDigit()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
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

    // MARK: - Feature Breakdown

    private var featureBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("业务场景与模式分布", "Feature & Mode Distribution"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TF.settingsText)

            let totalTokens = max(1, report.summary.totalTokens)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(report.featureBreakdowns.enumerated()), id: \.element.id) { index, item in
                        let ratio = Double(item.totalTokens) / Double(totalTokens)
                        if ratio > 0.01 {
                            Rectangle()
                                .fill(colorForBreakdown(item, at: index))
                                .frame(width: max(4, geo.size.width * CGFloat(ratio)))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 8)

            // Legend
            HStack(spacing: 14) {
                ForEach(Array(report.featureBreakdowns.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForBreakdown(item, at: index))
                            .frame(width: 6, height: 6)
                        Text(item.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextSecondary)
                        Text(String(format: "(%d)", item.requestCount))
                            .font(.system(size: 9))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TF.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }

    // MARK: - Recent Requests Section Content

    private var recentRequestsSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Pagination Top Bar
            HStack {
                Text(String(format: L("共 %d 条记录 · 第 %d 页 / 共 %d 页", "Total %d · Page %d of %d"),
                            recentTotalCount,
                            recentCurrentPage,
                            max(1, Int(ceil(Double(recentTotalCount) / Double(recentPageSize))))))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextSecondary)

                Spacer()

                // Page size selector
                HStack(spacing: 4) {
                    Text(L("每页:", "Page size:"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)

                    ForEach([20, 50, 100], id: \.self) { size in
                        Button {
                            recentPageSize = size
                            recentCurrentPage = 1
                            Task { await loadRecentRecords() }
                        } label: {
                            Text("\(size)")
                                .font(.system(size: 10, weight: recentPageSize == size ? .bold : .regular))
                                .foregroundStyle(recentPageSize == size ? TF.settingsText : TF.settingsTextTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(recentPageSize == size ? Capsule().fill(TF.settingsControl) : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Pagination navigation buttons
                HStack(spacing: 4) {
                    Button {
                        guard recentCurrentPage > 1 else { return }
                        recentCurrentPage -= 1
                        Task { await loadRecentRecords() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(recentCurrentPage > 1 ? TF.settingsText : TF.settingsTextTertiary.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsCard))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(TF.settingsBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(recentCurrentPage <= 1)

                    Button {
                        guard recentHasMore else { return }
                        recentCurrentPage += 1
                        Task { await loadRecentRecords() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(recentHasMore ? TF.settingsText : TF.settingsTextTertiary.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsCard))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(TF.settingsBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!recentHasMore)
                }
            }

            VStack(spacing: 0) {
                // Table Header
                HStack(spacing: 10) {
                    Text(L("时间 / 场景模式", "Time / Mode"))
                        .frame(width: 140, alignment: .leading)
                    Text(L("模型 / 厂商", "Model / Provider"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("输入 Token", "Prompt"))
                        .frame(width: 75, alignment: .trailing)
                    Text(L("输出 Token", "Comp"))
                        .frame(width: 75, alignment: .trailing)
                    Text(L("耗时", "Time"))
                        .frame(width: 65, alignment: .trailing)
                    Text(L("成本", "Cost"))
                        .frame(width: 75, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TF.settingsControl)
                Divider()

                if recentRecords.isEmpty {
                    Text(L("暂无逐条请求记录", "No invocation records found"))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recentRecords) { record in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(formatDate(record.createdAt))
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(TF.settingsText)
                                    HStack(spacing: 3) {
                                        Circle()
                                            .fill(featureColor(for: record.featureSource))
                                            .frame(width: 5, height: 5)
                                        Text(record.modeName ?? record.featureSource.localizedDisplayName)
                                            .font(.system(size: 9))
                                            .foregroundStyle(TF.settingsTextTertiary)
                                    }
                                }
                                .frame(width: 140, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.model)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(TF.settingsText)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(record.provider)
                                        if record.isEstimated {
                                            Text(L("[估算]", "[est]"))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .font(.system(size: 9))
                                    .foregroundStyle(TF.settingsTextTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(formatTokens(record.promptTokens))
                                    .frame(width: 75, alignment: .trailing)
                                Text(formatTokens(record.completionTokens))
                                    .frame(width: 75, alignment: .trailing)
                                Text(String(format: "%.2fs", record.durationSeconds))
                                    .frame(width: 65, alignment: .trailing)

                                HStack {
                                    let rate = LLMPricingRegistry.rate(for: record.model, provider: record.provider)
                                    if rate.isFree {
                                        Text(L("免费", "Free"))
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.green)
                                    } else if rate.isUnknown {
                                        Text("—")
                                            .foregroundStyle(TF.settingsTextTertiary)
                                            .settingsTooltip(L("该模型暂未收录费率，仅统计 Token", "Rate not in catalog; tokens only"))
                                    } else {
                                        Text(formatCostUSD(record.costUSD))
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                    }
                                }
                                .frame(width: 75, alignment: .trailing)
                            }
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(TF.settingsText)
                            .monospacedDigit()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
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
        async let reportFetch = historyStore.getLLMUsageReport(from: selectedRange.startDate, to: nil)
        async let dailyModelFetch = historyStore.fetchLLMDailyModelBreakdown(from: selectedRange.startDate, to: nil)

        let (rep, dailyModels) = await (reportFetch, dailyModelFetch)
        self.report = rep
        self.dailyModelItems = dailyModels
        await loadRecentRecords()
    }

    private func loadRecentRecords() async {
        let paginated = await historyStore.getPaginatedLLMUsageRecords(
            page: recentCurrentPage,
            pageSize: recentPageSize,
            from: selectedRange.startDate,
            to: nil
        )
        self.recentRecords = paginated.records
        self.recentTotalCount = paginated.totalCount
        self.recentHasMore = paginated.hasMore
    }

    // MARK: - Helpers

    private static let modeColorPalette: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan, .yellow, .green
    ]

    private func colorForBreakdown(_ item: HistoryStore.LLMFeatureBreakdown, at index: Int) -> Color {
        if item.feature != .dictationPolish {
            return featureColor(for: item.feature)
        }
        let palette = Self.modeColorPalette
        return palette[abs(index) % palette.count]
    }

    private func featureColor(for feature: LLMFeatureSource) -> Color {
        switch feature {
        case .dictationPolish: return .blue
        case .voiceRevise:     return .purple
        case .askAnything:     return .orange
        case .vocabSuggestion: return .teal
        case .macAction:       return .indigo
        case .batchCorrection: return .green
        case .other:           return .gray
        }
    }
    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2f M", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1f K", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func formatCostUSD(_ cost: Double) -> String {
        if cost < 0.001 && cost > 0 {
            return "< $0.001"
        }
        return String(format: "$%.3f", cost)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
