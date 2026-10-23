import AppKit
import SwiftUI

/// Recent dictation on Home, newest first across days: what was said, where
/// it went, which mode handled it, and what the LLM changed.
struct HomeTodayFeed: View {
    let records: [HistoryRecord]
    let modes: [ProcessingMode]
    let hasLoaded: Bool
    let onCorrect: (HistoryRecord) -> Void

    @AppStorage("tf_homeHideContent") private var hideContent = false
    @State private var filter: UUID?
    @State private var searchText = ""
    @State private var hoveredId: String?
    @State private var copiedId: String?

    /// The list scrolls inside the card, so a taller window shows more rows.
    private let visibleLimit = 50

    private struct Item: Identifiable {
        let record: HistoryRecord
        let modeId: UUID?
        var id: String { record.id }
    }

    var body: some View {
        let items = records.map {
            Item(record: $0, modeId: HomeModeUsage.resolve(modeId: $0.processingModeId, modeName: $0.processingMode, modes: modes))
        }
        let filtered = filter.map { selected in items.filter { $0.modeId == selected } } ?? items
        let visible = Array(filtered.prefix(visibleLimit))

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("最近说过的话", "Recent dictation"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Button(L("全部历史", "All history")) { HistorySearchRequest.open(query: nil) }
                    .buttonStyle(.tf(.ghost, size: .small))
            }

            HStack(spacing: 8) {
                searchField
                filterPicker(options: filterOptions(items))
                Button {
                    hideContent.toggle()
                } label: {
                    Image(systemName: hideContent ? "eye.slash" : "eye")
                }
                .buttonStyle(.tfIcon())
                .settingsTooltip(hideContent ? L("显示内容", "Show text") : L("隐藏内容", "Hide text"))
            }

            if visible.isEmpty {
                emptyState(isFiltered: filter != nil && !items.isEmpty)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < visible.count - 1 {
                                Divider()
                            }
                        }
                        Button(L("查看全部历史", "View all history")) {
                            HistorySearchRequest.open(query: nil)
                        }
                        .buttonStyle(.tf(.ghost, size: .small))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Fills the row height so both columns end together.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .dashboardCard()
        .onChange(of: modes.map(\.id)) { _, ids in
            if let filter, !ids.contains(filter) { self.filter = nil }
        }
    }

    // MARK: - Toolbar

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
            TextField(L("搜索你说过的话", "Search what you said"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    searchText = ""
                    HistorySearchRequest.open(query: query)
                }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TF.settingsControl)
        )
        .settingsTooltip(L("回车后在历史中搜索", "Press Return to search all history"))
    }

    /// The modes used most today, so the filter only offers choices that
    /// return something.
    private func filterOptions(_ items: [Item]) -> [ProcessingMode] {
        var counts: [UUID: Int] = [:]
        for item in items {
            if let id = item.modeId { counts[id, default: 0] += 1 }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { entry in modes.first { $0.id == entry.key } }
    }

    private func filterPicker(options: [ProcessingMode]) -> some View {
        HStack(spacing: 2) {
            filterSegment(L("全部", "All"), selected: filter == nil) { filter = nil }
            ForEach(options) { mode in
                filterSegment(mode.localizedDisplayName, selected: filter == mode.id) { filter = mode.id }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(TF.settingsCardAlt))
        .fixedSize()
    }

    private func filterSegment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? TF.settingsText : TF.settingsTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? TF.settingsCard : Color.clear)
                        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private func row(_ item: Item) -> some View {
        let record = item.record
        let isHovered = hoveredId == record.id
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let day = Self.dayLabel(for: record.createdAt) {
                    Text(day)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }
                Text(Self.timeFormatter.string(from: record.createdAt))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .frame(width: 44, alignment: .leading)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    meta(record, modeId: item.modeId)
                    Spacer(minLength: 8)
                    actions(record)
                        .opacity(isHovered || copiedId == record.id ? 1 : 0)
                }

                Text(record.finalText)
                    .font(.system(size: 14))
                    .foregroundStyle(TF.settingsText)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blur(radius: hideContent ? 5 : 0)

                changeView(record)
                    .blur(radius: hideContent ? 5 : 0)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { hoveredId = hovering ? record.id : nil }
        }
    }

    private func meta(_ record: HistoryRecord, modeId: UUID?) -> some View {
        HStack(spacing: 8) {
            if let appLabel = record.targetAppName
                ?? record.targetBundleId.flatMap(HomeAppIconCache.name(for:))
                ?? record.targetBundleId {
                HStack(spacing: 5) {
                    HomeAppIcon(bundleId: record.targetBundleId, size: 14)
                    Text(appLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(1)
                }
            }
            if let label = modeLabel(record, modeId: modeId) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 19)
                    .background(Capsule().fill(TF.settingsCardAlt))
            }
            Text(L("\(record.characterCount ?? record.finalText.count) 字", "\(record.characterCount ?? record.finalText.count) chars"))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize()
        }
    }

    private func modeLabel(_ record: HistoryRecord, modeId: UUID?) -> String? {
        guard let mode = modeId.flatMap({ id in modes.first { $0.id == id } }) else {
            return record.processingMode
        }
        guard let binding = mode.hotkeyBindings.first else { return mode.localizedDisplayName }
        let key = HotkeyRecorderView.keyDisplayName(keyCode: binding.keyCode, modifiers: binding.modifiers)
        return "\(mode.localizedDisplayName) · \(key)"
    }

    private func actions(_ record: HistoryRecord) -> some View {
        HStack(spacing: 4) {
            Button { onCorrect(record) } label: {
                Image(systemName: "character.textbox")
            }
            .buttonStyle(.tfIcon())
            .settingsTooltip(L("纠错并加入词汇", "Correct and add to vocabulary"))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.finalText, forType: .string)
                copiedId = record.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedId == record.id { copiedId = nil }
                }
            } label: {
                Image(systemName: copiedId == record.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.tfIcon(tint: copiedId == record.id ? TF.settingsAccentGreen : nil))
            .settingsTooltip(copiedId == record.id ? L("已复制", "Copied") : L("复制", "Copy"))
        }
    }

    /// What the LLM changed. Edits read as a diff; a rewrite (or a translation)
    /// shows the original instead, since a diff of it is mostly noise.
    @ViewBuilder
    private func changeView(_ record: HistoryRecord) -> some View {
        let baseline = record.postSnippetText ?? record.rawText
        if record.llmProvider != nil, !baseline.isEmpty, baseline != record.finalText {
            Group {
                if let segments = HomeTextDiff.segments(from: baseline, to: record.finalText),
                   HomeTextDiff.unchangedRatio(segments, originalLength: baseline.count) >= 0.35 {
                    Text(Self.attributed(segments))
                } else {
                    Text(L("原话：", "Original: ") + baseline)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(TF.settingsTextTertiary)
            .lineSpacing(3)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TF.settingsBg)
            )
        }
    }

    static func attributed(_ segments: [HomeTextDiff.Segment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .removed:
                part.foregroundColor = TF.settingsAccentRed
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: TF.settingsAccentRed.opacity(0.7))
            case .inserted:
                part.foregroundColor = TF.settingsText
                part.backgroundColor = TF.settingsAccentBlue.opacity(0.14)
            }
            result += part
        }
        return result
    }

    @ViewBuilder
    private func emptyState(isFiltered: Bool) -> some View {
        VStack(spacing: 6) {
            if hasLoaded {
                Text(isFiltered
                     ? L("这个模式最近没有用过", "This mode hasn't been used recently")
                     : L("还没有说话记录", "Nothing dictated yet"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.settingsTextSecondary)
                if !isFiltered {
                    Text(L("按下模式的快捷键说一句话，内容会出现在这里。", "Press a mode's hotkey and speak. What you say shows up here."))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    /// Nothing for today, "昨天" for yesterday, otherwise a short date.
    static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        if calendar.isDate(date, inSameDayAs: now) { return nil }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L("昨天", "Yesterday")
        }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)/\(day)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// Icons and display names for target apps, looked up once per bundle ID.
@MainActor
enum HomeAppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(for bundleId: String) -> NSImage? {
        if let cached = icons[bundleId] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleId] = icon
        return icon
    }

    static func name(for bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct HomeAppIcon: View {
    let bundleId: String?
    let size: CGFloat

    var body: some View {
        if let image = bundleId.flatMap(HomeAppIconCache.icon(for:)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(TF.settingsCardAlt)
                .frame(width: size, height: size)
        }
    }
}
