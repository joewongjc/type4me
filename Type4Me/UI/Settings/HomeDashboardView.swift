import SwiftUI

/// Home: the user's modes on top (collapsed to one row by default), recent
/// dictation as the main column, and cumulative growth plus where the text
/// went alongside.
struct HomeDashboardView: View {
    let isActive: Bool
    let openModesEditor: (UUID?) -> Void

    @Environment(AppState.self) private var appState
    @Environment(AppNavigationModel.self) private var navigationModel
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage("tf_homeModesExpanded") private var modesExpanded = false

    @State private var statistics: HistoryStore.Statistics?
    @State private var activityDays: [HistoryStore.ActivityDay] = []
    @State private var recentRecords: [HistoryRecord] = []
    @State private var modeCounts: [UUID: Int] = [:]
    @State private var apps: [HistoryStore.AppUsage] = []
    @State private var hasLoaded = false
    /// Live-editable mirror of `appState.availableModes`, kept in sync so the
    /// Home card can reorder and edit hotkeys inline and persist back.
    @State private var modes: [ProcessingMode] = []
    @State private var recordingTarget: RecordingTarget?
    @State private var draggingModeID: UUID?
    @State private var correctionRecord: HistoryRecord?
    @State private var chipWidths: [UUID: CGFloat] = [:]
    /// Height of the modes card while collapsed. The lower row is sized from
    /// this, so expanding the modes pushes the cards down (the page scrolls)
    /// instead of shrinking them. Seeded with the one-row height for launches
    /// that start expanded.
    @State private var collapsedModesHeight: CGFloat = 56

    private let historyStore = HistoryStore.shared
    private let assumedTypingSpeed = 40.0
    /// Recent records are filtered by mode on the page, so fetch more than are shown.
    private let recentFetchLimit = 200
    /// Natural height of the side column at its smallest. Below this the page
    /// scrolls instead of squeezing the cards.
    private let lowerMinHeight: CGFloat = 520

    /// Always two columns. The lower row fills the window below the collapsed
    /// modes card, so the cards grow with the window and keep their height when
    /// the modes expand; the page scrolls when content runs past the window.
    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    modesCard
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            if !modesExpanded { collapsedModesHeight = height }
                        }

                    HStack(alignment: .top, spacing: 16) {
                        feed
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        sideColumn
                            .frame(width: 300)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: max(proxy.size.height - collapsedModesHeight - 16, lowerMinHeight))
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(language)
        .sheet(item: $recordingTarget) { target in
            HotkeyRecordingSheet(
                target: target,
                checkConflict: ModeHotkeyEditing.makeConflictCheck(in: modes, target: target),
                checkDuplicateInMode: ModeHotkeyEditing.makeDuplicateCheck(in: modes, target: target),
                checkPrefixConflict: ModeHotkeyEditing.makePrefixConflictCheck(in: modes, target: target),
                onConfirm: { code, mods, style in
                    ModeHotkeyEditing.applyBinding(
                        keyCode: code, modifiers: mods, style: style,
                        to: &modes, for: target
                    )
                    persistHomeModes()
                    recordingTarget = nil
                },
                onCancel: { recordingTarget = nil }
            )
        }
        .sheet(item: $correctionRecord) { record in
            QuickCorrectionSheet(text: record.rawText, provenance: CorrectionProvenance(record: record))
        }
        .onAppear {
            syncModes()
            if isActive { refreshDashboard() }
        }
        .onChange(of: isActive) { _, isNowActive in
            if isNowActive { refreshDashboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            if isActive { refreshDashboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMode)) { _ in
            syncModes()
            refreshDashboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modesDidChange)) { _ in
            syncModes()
            refreshDashboard()
        }
    }

    private var feed: some View {
        HomeTodayFeed(
            records: recentRecords,
            modes: modes,
            hasLoaded: hasLoaded,
            onCorrect: { correctionRecord = $0 }
        )
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HomeGrowthCard(
                summary: HomeGrowthSummary(activityDays: activityDays),
                activity: HomeActivitySummary(activityDays: activityDays),
                totalCharacters: statistics?.totalCharacters ?? 0,
                totalDuration: statistics?.totalDuration ?? 0,
                savedDuration: estimatedSavedTime(statistics),
                averageSpeed: statistics?.averageSpeed ?? 0
            )
            HomeAppsCard(apps: apps)
        }
    }

    // MARK: - Modes

    private var boundModes: [ProcessingMode] {
        modes.filter { !$0.hotkeyBindings.isEmpty }
    }

    private var modesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L("我的模式", "My Modes"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                    .fixedSize()

                if modesExpanded {
                    Spacer(minLength: 0)
                } else {
                    collapsedStrip
                }

                Button {
                    withAnimation(TF.easeQuick) { modesExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(modesExpanded ? L("收起", "Collapse") : L("展开", "Expand"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(modesExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.tf(.secondary, size: .small))

                Button(action: { openModesEditor(nil) }) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.tfIcon())
                .settingsTooltip(L("管理模式", "Manage modes"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if modesExpanded {
                Divider().padding(.horizontal, 16)
                expandedModes
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .dashboardCard()
    }

    @ViewBuilder
    private var collapsedStrip: some View {
        let bound = boundModes
        if bound.isEmpty {
            Text(L("还没有给模式绑定快捷键，展开后即可添加", "No hotkeys yet. Expand to add one."))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GeometryReader { proxy in
                let visible = Self.visibleChipCount(
                    widths: bound.map { chipWidths[$0.id] ?? 0 },
                    available: proxy.size.width
                )
                HStack(spacing: 8) {
                    ForEach(bound.prefix(visible)) { mode in
                        modeChip(mode)
                    }
                    if visible < bound.count {
                        Text("+\(bound.count - visible)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 30)
            .background(alignment: .leading) {
                HStack(spacing: 8) {
                    ForEach(bound) { mode in
                        modeChip(mode)
                            .fixedSize()
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: HomeChipWidthKey.self,
                                    value: [mode.id: geometry.size.width]
                                )
                            })
                    }
                }
                .fixedSize()
                .hidden()
            }
            .onPreferenceChange(HomeChipWidthKey.self) { chipWidths = $0 }
        }
    }

    /// How many chips fit, leaving room for the "+N" overflow label when some
    /// do not.
    static func visibleChipCount(widths: [CGFloat], available: CGFloat, spacing: CGFloat = 8, overflowWidth: CGFloat = 30) -> Int {
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        if total <= available { return widths.count }
        var used: CGFloat = 0
        var count = 0
        for width in widths {
            let next = used + (count > 0 ? spacing : 0) + width
            if next + spacing + overflowWidth > available { break }
            used = next
            count += 1
        }
        return count
    }

    private func modeChip(_ mode: ProcessingMode) -> some View {
        HStack(spacing: 7) {
            Text(mode.localizedDisplayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
            if let binding = mode.hotkeyBindings.first {
                HomeHotkeyBadge(binding: binding)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Capsule().fill(TF.settingsBg))
        .contentShape(Capsule())
        .onTapGesture { openModesEditor(mode.id) }
    }

    private var expandedModes: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            ForEach(modes) { mode in
                modeTile(mode)
            }
            Button {
                navigationModel.pendingModeCreation = true
                openModesEditor(nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L("新建模式", "New mode"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(maxWidth: .infinity, minHeight: 104)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(TF.settingsTextTertiary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            // Fallback: reset drag state when released over empty grid space.
            if draggingModeID != nil {
                persistHomeModes()
                draggingModeID = nil
            }
            return true
        }
    }

    private func modeTile(_ mode: ProcessingMode) -> some View {
        let count = modeCounts[mode.id] ?? 0
        let hasBindings = !mode.hotkeyBindings.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mode.localizedDisplayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(L("今天 \(count) 次", "\(count) today"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize()
                if hasBindings {
                    Button { addBinding(mode) } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.tfIcon())
                    .settingsTooltip(L("添加快捷键", "Add hotkey"))
                }
            }

            HotkeySectionView(
                bindings: mode.hotkeyBindings,
                onEdit: { editBinding(mode, $0) },
                onDelete: { deleteBinding(mode.id, $0) },
                onAdd: { addBinding(mode) },
                showsHeader: false,
                showsAddButton: !hasBindings
            )

            Spacer(minLength: 0)

            let description = mode.localizedDisplayDescription
            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TF.settingsBg)
        )
        .contentShape(Rectangle())
        .onTapGesture { openModesEditor(mode.id) }
        .opacity(draggingModeID == mode.id ? 0.45 : 1)
        .onDrag {
            draggingModeID = mode.id
            return NSItemProvider(object: mode.id.uuidString as NSString)
        } preview: {
            Text(mode.localizedDisplayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.settingsText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(TF.settingsCard))
        }
        .onDrop(of: [.text], delegate: ModeDropDelegate(
            targetId: mode.id,
            modes: $modes,
            draggingId: $draggingModeID,
            onReorder: { persistHomeModes() }
        ))
    }

    // MARK: - Mode state + hotkey editing
    /// Mirror `appState.availableModes` into local editable state. The Home card
    /// mutates `modes` for reorder/hotkey edits and persists back through the
    /// shared helper, which broadcasts `.modesDidChange` to re-sync every source.
    private func syncModes() {
        modes = appState.availableModes
    }

    @discardableResult
    private func persistHomeModes() -> Bool {
        ModeHotkeyEditing.persistModes(modes, appState: appState)
    }

    private func editBinding(_ mode: ProcessingMode, _ binding: HotkeyBinding) {
        recordingTarget = RecordingTarget(
            modeId: mode.id,
            modeName: mode.localizedDisplayName,
            editingBindingId: binding.id,
            initialKeyCode: binding.keyCode,
            initialModifiers: binding.modifiers,
            initialStyle: binding.style
        )
    }

    private func addBinding(_ mode: ProcessingMode) {
        recordingTarget = RecordingTarget(
            modeId: mode.id,
            modeName: mode.localizedDisplayName,
            editingBindingId: nil,
            initialKeyCode: nil,
            initialModifiers: nil,
            initialStyle: ProcessingMode.defaultHotkeyStyle
        )
    }

    private func deleteBinding(_ modeId: UUID, _ binding: HotkeyBinding) {
        if let idx = modes.firstIndex(where: { $0.id == modeId }) {
            modes[idx].hotkeyBindings.removeAll { $0.id == binding.id }
            persistHomeModes()
        }
    }

    // MARK: - Data

    private func refreshDashboard() {
        Task {
            let calendar = Calendar.current
            let now = Date()
            let todayStart = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now

            async let newStatistics = historyStore.getStatistics()
            async let newActivityDays = historyStore.getActivityDays()
            async let newRecentRecords = historyStore.dictationRecords(from: .distantPast, to: tomorrow, limit: recentFetchLimit)
            async let newModeRows = historyStore.modeUsageRows(from: todayStart, to: tomorrow)
            async let newApps = historyStore.appUsage(from: .distantPast, to: tomorrow, limit: 4)

            statistics = await newStatistics
            activityDays = await newActivityDays
            recentRecords = await newRecentRecords
            modeCounts = HomeModeUsage.counts(rows: await newModeRows, modes: appState.availableModes)
            apps = await newApps
            hasLoaded = true
        }
    }

    private func estimatedSavedTime(_ stats: HistoryStore.Statistics?) -> Double {
        guard let stats else { return 0 }
        let estimatedTypingSeconds = Double(stats.totalCharacters) / assumedTypingSpeed * 60
        return max(0, estimatedTypingSeconds - stats.totalDuration)
    }
}

/// Read-only hotkey capsule for the collapsed modes row, styled like the
/// editable capsules in `HotkeySectionView`.
struct HomeHotkeyBadge: View {
    let binding: HotkeyBinding

    var body: some View {
        let accent = HotkeySectionView.styleColor(binding.style)
        HStack(spacing: 4) {
            Image(systemName: HotkeySectionView.styleIcon(binding.style))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent)
            Text(HotkeyRecorderView.keyDisplayName(keyCode: binding.keyCode, modifiers: binding.modifiers))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
    }
}

private struct HomeChipWidthKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Pure summary logic kept separate from SwiftUI so streak behavior is easy to
/// validate and remains deterministic at local calendar-day boundaries.
struct HomeActivitySummary: Equatable {
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int

    init(
        activityDays: [HistoryStore.ActivityDay],
        today: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputCalendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let activeDates = Set(activityDays.lazy.filter { $0.recordCount > 0 }.compactMap {
            formatter.date(from: $0.dayIdentifier).map(calendar.startOfDay(for:))
        })
        activeDays = activeDates.count

        let sortedDates = activeDates.sorted()
        var longest = 0
        var running = 0
        var previous: Date?
        for date in sortedDates {
            if let previous,
               calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                running += 1
            } else {
                running = 1
            }
            longest = max(longest, running)
            previous = date
        }
        longestStreak = longest

        let localToday = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: localToday) ?? localToday
        var cursor: Date?
        if activeDates.contains(localToday) {
            cursor = localToday
        } else if activeDates.contains(yesterday) {
            cursor = yesterday
        } else {
            cursor = nil
        }

        var current = 0
        while let day = cursor, activeDates.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        currentStreak = current
    }
}

extension View {
    func dashboardCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TF.settingsCard)
                .shadow(color: Color.black.opacity(0.035), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }
}

/// A very light perspective dot field used only behind the Home dashboard.
struct HomeDottedWaveBackground: View {
    var body: some View {
        Canvas { context, size in
            let projectedX: CGFloat = 7.8
            let projectedY: CGFloat = 7.2
            let originX = size.width * 0.50
            let originY = size.height * 0.48
            let indexRadius = Int(ceil(
                size.width / (projectedX * 2) + size.height / (projectedY * 2)
            )) + 8
            let waveCenterX = size.width * 0.68
            let waveCenterY = size.height * 0.63
            let scaleX = max(size.width * 0.58, 1)
            let scaleY = max(size.height * 0.64, 1)

            for u in -indexRadius...indexRadius {
                for v in -indexRadius...indexRadius {
                    let baseX = originX + CGFloat(u - v) * projectedX
                    let baseY = originY + CGFloat(u + v) * projectedY
                    guard baseX > -12, baseX < size.width + 12,
                          baseY > -44, baseY < size.height + 18 else { continue }

                    let nx = (baseX - waveCenterX) / scaleX
                    let ny = (baseY - waveCenterY) / scaleY
                    let envelope = exp(-(nx * nx * 0.82 + ny * ny * 1.05))
                    let wave = sin(nx * 6.2 + ny * 1.4)
                        * cos(ny * 2.3 - nx * 0.55)
                        * envelope
                    let x = baseX - wave * 5.5
                    let y = baseY - wave * 46
                    let nearFactor = 0.72
                        + min(max(baseY / max(size.height, 1), 0), 1) * 0.28
                    let crest = (wave + envelope + 1) / 3
                    let radius = (0.78 + crest * 0.52) * nearFactor
                    let opacity = (0.055 + envelope * (0.018 + crest * 0.04)) * nearFactor
                    let dot = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(TF.settingsInk.opacity(opacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
