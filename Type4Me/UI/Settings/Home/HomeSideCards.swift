import SwiftUI

enum HomeFormat {
    static func duration(_ seconds: Double) -> String {
        if seconds <= 0 { return L("0 分钟", "0 min") }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 1 { return L("< 1 分钟", "< 1 min") }
        if totalMinutes < 60 { return L("\(totalMinutes) 分钟", "\(totalMinutes) min") }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? L("\(hours) 小时", "\(hours) hr")
            : L("\(hours) 小时 \(minutes) 分", "\(hours) hr \(minutes) min")
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private func homeCardTitle(_ title: String, subtitle: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(TF.settingsText)
            .lineLimit(1)
        Spacer(minLength: 8)
        Text(subtitle)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(TF.settingsTextTertiary)
            .lineLimit(1)
    }
}

// MARK: - Growth

/// Cumulative characters since the first day of use, with recent milestones on
/// the curve, above the lifetime totals that used to be the overview tiles.
struct HomeGrowthCard: View {
    let summary: HomeGrowthSummary
    let activity: HomeActivitySummary
    let totalCharacters: Int
    let totalDuration: Double
    let savedDuration: Double
    let averageSpeed: Double

    private let labelSpace: CGFloat = 16
    private let axisSpace: CGFloat = 18
    /// The plot grows with the card when the window is taller than the minimum.
    private let minPlotHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            homeCardTitle(L("累计字数", "Total characters"), subtitle: L("使用以来", "Since you started"))
            curve
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile(L("总字数", "Characters"), HomeFormat.number(totalCharacters))
                        .settingsTooltip(String(format: L("平均输入速度 %.0f 字/分", "Average speed %.0f chars/min"), averageSpeed))
                    tile(L("输入总时间", "Input time"), HomeFormat.duration(totalDuration))
                }
                GridRow {
                    tile(L("估算节约", "Time saved"), HomeFormat.duration(savedDuration))
                    tile(
                        L("活跃 / 连续", "Active / streak"),
                        L("\(activity.activeDays) 天 · \(activity.currentStreak) 天", "\(activity.activeDays) d · \(activity.currentStreak) d")
                    )
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(16)
        .dashboardCard()
    }

    @ViewBuilder
    private var curve: some View {
        if let startDate = summary.startDate {
            GeometryReader { proxy in
                let geometry = CurveGeometry(
                    cumulative: summary.cumulative,
                    width: proxy.size.width,
                    top: labelSpace,
                    bottom: proxy.size.height - axisSpace
                )
                ZStack(alignment: .topLeading) {
                    geometry.area()
                        .fill(TF.settingsAccentBlue.opacity(0.12))
                    geometry.line()
                        .stroke(TF.settingsAccentBlue, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.bottom + 0.5))
                        path.addLine(to: CGPoint(x: geometry.width, y: geometry.bottom + 0.5))
                    }
                    .stroke(TF.settingsCardAlt, lineWidth: 1)

                    ForEach(summary.shownMilestones, id: \.value) { milestone in
                        milestoneMark(milestone, geometry: geometry)
                    }

                    axisLabel(L("\(Self.shortDate(startDate)) 开始", "Since \(Self.shortDate(startDate))"))
                        .offset(y: geometry.bottom + 5)
                    axisLabel(L("今天", "Today"))
                        .frame(width: geometry.width, alignment: .trailing)
                        .offset(y: geometry.bottom + 5)
                }
            }
            .frame(minHeight: labelSpace + minPlotHeight + axisSpace, maxHeight: .infinity)
        } else {
            Text(L("说出第一句话后，这里会画出你的累计字数。", "Your running total appears here after your first dictation."))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: labelSpace + minPlotHeight + axisSpace, maxHeight: .infinity)
        }
    }

    private func milestoneMark(_ milestone: HomeGrowthSummary.Milestone, geometry: CurveGeometry) -> some View {
        let point = geometry.point(reaching: milestone.value, at: milestone.position)
        let text = "\(Self.compactNumber(milestone.value)) · \(Self.shortDate(milestone.date))"
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(TF.settingsAccentBlue)
                .overlay(Circle().stroke(TF.settingsCard, lineWidth: 1.5))
                .frame(width: 7, height: 7)
                .offset(x: point.x - 3.5, y: point.y - 3.5)
            // Ends just left of the dot, but never past either card edge.
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TF.settingsAccentBlue)
                .fixedSize()
                .alignmentGuide(.leading) { d in
                    -min(max(0, point.x - d.width - 6), geometry.width - d.width)
                }
                .offset(y: max(0, point.y - 17))
        }
        .frame(width: geometry.width, alignment: .topLeading)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(TF.settingsTextTertiary)
            .fixedSize()
    }

    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }

    static func compactNumber(_ value: Int) -> String {
        if value >= 10_000, value % 10_000 == 0 {
            return L("\(value / 10_000) 万", "\(value / 1_000)k")
        }
        if value >= 1_000, value % 1_000 == 0 {
            return L(HomeFormat.number(value), "\(value / 1_000)k")
        }
        return HomeFormat.number(value)
    }

    /// Maps day totals to points: day `i` ends at `position(ofDay: i)` across
    /// the width, and the curve starts from zero at the left edge.
    struct CurveGeometry {
        let cumulative: [Int]
        let width: CGFloat
        let top: CGFloat
        let bottom: CGFloat

        private var peak: Double { Double(max(cumulative.last ?? 0, 1)) }

        private func y(_ value: Double) -> CGFloat {
            bottom - (bottom - top) * CGFloat(value / peak)
        }

        private func x(ofDay index: Int) -> CGFloat {
            width * CGFloat(HomeGrowthSummary.position(ofDay: index, dayCount: cumulative.count))
        }

        func line() -> Path {
            Path { path in
                path.move(to: CGPoint(x: 0, y: bottom))
                for (index, value) in cumulative.enumerated() {
                    path.addLine(to: CGPoint(x: x(ofDay: index), y: y(Double(value))))
                }
            }
        }

        func area() -> Path {
            var path = line()
            path.addLine(to: CGPoint(x: width, y: bottom))
            path.closeSubpath()
            return path
        }

        /// Where the curve crosses `value` within the day ending at `position`.
        func point(reaching value: Int, at position: Double) -> CGPoint {
            let day = max(0, min(cumulative.count - 1, Int((position * Double(cumulative.count)).rounded()) - 1))
            let before = day > 0 ? cumulative[day - 1] : 0
            let after = cumulative[day]
            let startX = day > 0 ? x(ofDay: day - 1) : 0
            let fraction = after > before ? CGFloat(value - before) / CGFloat(after - before) : 1
            return CGPoint(x: startX + (x(ofDay: day) - startX) * fraction, y: y(Double(value)))
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TF.settingsBg)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ranked lists

/// A ranked side card: title row, up to four label / bar / value rows in a
/// fixed-height list, and a footnote. Fixed row geometry keeps the card's
/// height stable as data arrives.
struct HomeRankedCard: View {
    struct Row: Identifiable {
        let id: String
        let label: AnyView
        let value: String
        let ratio: Double
    }

    static let maxRows = 4
    private static let rowHeight: CGFloat = 30
    private static let labelWidth: CGFloat = 96

    let title: String
    let subtitle: String
    let rows: [Row]
    let barTint: Color
    let emptyText: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            homeCardTitle(title, subtitle: subtitle)

            Group {
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows.prefix(Self.maxRows)) { row in
                            rowView(row)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(Self.maxRows))

            Text(footnote)
                .font(.system(size: 10.5))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .dashboardCard()
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 10) {
            row.label
                .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TF.settingsCardAlt)
                    Capsule()
                        .fill(barTint)
                        .frame(width: max(6, proxy.size.width * row.ratio))
                }
            }
            .frame(height: 6)
            Text(row.value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
    }
}

struct HomeAppsCard: View {
    let apps: [HistoryStore.AppUsage]

    var body: some View {
        let peak = Double(max(apps.map(\.characterCount).max() ?? 0, 1))
        HomeRankedCard(
            title: L("话说到了哪里", "Where it went"),
            subtitle: L("累计", "All time"),
            rows: apps.map { app in
                HomeRankedCard.Row(
                    id: app.key,
                    label: AnyView(
                        HStack(spacing: 7) {
                            HomeAppIcon(bundleId: app.bundleId, size: 16)
                            Text(app.appName ?? app.bundleId.flatMap(HomeAppIconCache.name(for:)) ?? app.key)
                                .font(.system(size: 13))
                                .foregroundStyle(TF.settingsText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    ),
                    value: HomeFormat.number(app.characterCount),
                    ratio: Double(app.characterCount) / peak
                )
            },
            barTint: TF.settingsText,
            emptyText: L("说几句话后，这里会显示文字写进了哪个 App。",
                         "Dictate a few times to see which apps your text goes to."),
            footnote: L("按字数统计；旧记录只有经过智能感知的能找回 App",
                        "By characters. Older records only know the app if Intelli Sense handled them")
        )
    }
}
