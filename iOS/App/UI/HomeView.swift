import SwiftUI

/// Home, laid out like the Mac Home: the logo, the import card until it is dismissed,
/// totals, modes and recent dictation. The voice session runs on its own
/// while the app is open or in the background, so it has no card here.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryStore
    @State private var importDismissed = AppSettings.importCardDismissed
    @ObservedObject private var updates = UpdateCheck.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    BrandMark(size: 30)
                    Text("Type4Me")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(T4.ink)
                    Spacer()
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if let update = updates.available {
                    UpdateCard(update: update) { updates.dismiss() }
                }
                if !importDismissed {
                    ImportCard {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { importDismissed = true }
                        AppSettings.importCardDismissed = true
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                }
                StatsCard()
                ModesCard()
                RecentCard()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .onAppear { importDismissed = AppSettings.importCardDismissed }
        // No navigation bar on Home, so supply the soft scroll-edge blur
        // under the status bar ourselves.
        .safeAreaBar(edge: .top) { Color.clear.frame(height: 0) }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(DottedCanvas())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Bringing the Mac setup over is how the iPhone gets its services, so it
/// sits on Home: scan in-app or paste, and see what was last imported.
/// Swipe it sideways or tap ✕ to put it away; Settings keeps both imports.
struct ImportCard: View {
    @EnvironmentObject private var model: AppModel
    let onDismiss: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(T4.ink)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("从 Mac 同步", "Sync from Mac"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(T4.ink)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(T4.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(T4.secondary)
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("关闭", "Close"))
                .accessibilityHint(L("可以在设置 › 识别与处理里继续导入", "You can still import from Settings › Speech & Text"))
            }

            Button {
                model.showsScanner = true
            } label: {
                Label(L("扫码同步", "Scan to Sync"), systemImage: "qrcode.viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T4.background)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.glassProminent)
            .tint(T4.ink)
        }
        .t4Card(padding: 18)
        .offset(x: dragX)
        .opacity(1 - min(abs(dragX) / 320, 0.6))
        .simultaneousGesture(
            // Horizontal only, so vertical scrolling through Home is untouched.
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    let distance = abs(value.translation.width)
                    let flung = abs(value.predictedEndTranslation.width) > 220
                    if distance > 110 || (flung && distance > 40) {
                        withAnimation(.easeOut(duration: 0.2)) { dragX = value.translation.width > 0 ? 500 : -500 }
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                    }
                }
        )
        .accessibilityAction(named: L("关闭", "Close"), onDismiss)
    }

    private var detail: String {
        guard model.hasConfig, let meta = ConfigStore.meta else {
            return L(
                "在 Mac 版 Type4Me 的侧边栏打开「手机版」，用下面的按钮扫码。密钥只存在这台 iPhone 的钥匙串里。",
                "In Type4Me on your Mac, open Mobile in the sidebar, then scan the code with the button below. Keys stay in this iPhone's Keychain."
            )
        }
        let services = [
            ConfigStore.asr.map { ProviderNames.asr($0.provider) },
            ConfigStore.llm.map { ProviderNames.llm($0.provider) },
        ].compactMap { $0 }.joined(separator: " + ")
        let date = meta.importedAt.formatted(
            .dateTime.month(.defaultDigits).day().hour().minute().locale(AppLanguage.current.locale)
        )
        let source = meta.sourceName ?? "Mac"
        return "✓ \(services)\n" + L("来自 \(source) · \(date)", "From \(source) · \(date)")
    }
}

/// The grey totals card from the Mac Home side column, as glass over the
/// dotted canvas.
struct StatsCard: View {
    @EnvironmentObject private var history: HistoryStore

    /// Typing at 40 characters a minute against speaking at about 200, the
    /// same assumption the Mac Home uses for saved time.
    private var savedMinutes: Int {
        Int((Double(history.totalCharacterCount) * (1.0 / 40 - 1.0 / 200)).rounded())
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow {
                stat("sun.max", chars(history.todayCharacterCount), L("今天", "Today"))
                stat("mic", chars(history.totalCharacterCount), L("累计", "All time"))
            }
            GridRow {
                let count = history.entries.filter { $0.delivered != .failed }.count.formatted()
                stat("text.bubble", L("\(count) 次", count), L("说过", "Dictations"))
                stat("hourglass", savedText, L("约节省", "Time saved"))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(T4.cardAlt.opacity(0.35)), in: RoundedRectangle(cornerRadius: T4.cornerCard, style: .continuous))
    }

    private var savedText: String {
        let minutes = savedMinutes
        if minutes < 60 { return L("\(minutes) 分钟", "\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return L("\(hours) 小时", "\(hours) hr") }
        return L("\(hours) 小时 \(rest) 分", "\(hours) hr \(rest) min")
    }

    private func chars(_ count: Int) -> String {
        L("\(count.formatted()) 字", "\(count.formatted()) chars")
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(T4.ink)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(T4.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(T4.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "我的模式": a heading above the card and one selectable row per mode,
/// the selected one marked like a radio choice.
struct ModesCard: View {
    @ObservedObject private var modes = ModeStore.shared
    @EnvironmentObject private var model: AppModel
    @State private var selected = SharedSettings.selectedMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: L("我的模式", "My Modes"),
                subtitle: L("键盘默认用哪个，也可以在键盘顶部随时切换", "Choose the keyboard's default. You can switch anytime at the top of the keyboard.")
            ) {
                Button(L("管理", "Manage")) { model.showModeSettings() }
                    .buttonStyle(.glass)
                    .tint(T4.ink)
                    .controlSize(.small)
            }
            VStack(spacing: 0) {
                ForEach(Array(DictationMode.keyboardOrder.enumerated()), id: \.element) { index, mode in
                    if index > 0 { Divider().overlay(T4.border).padding(.leading, 58) }
                    row(mode)
                }
            }
            .t4Card(padding: 0)
        }
        .onAppear { selected = SharedSettings.selectedMode }
        .onChange(of: modes.modes) { _, _ in selected = SharedSettings.selectedMode }
    }

    private func row(_ mode: DictationMode) -> some View {
        let available = !mode.usesLLM || SharedSettings.llmConfigured
        // The keyboard falls back to 快速 when the text model is missing.
        let effective = (!selected.usesLLM || SharedSettings.llmConfigured) ? selected : .quick
        let isSelected = effective == mode
        return Button {
            guard available else { return }
            SharedSettings.selectedMode = mode
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = mode }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(T4.ink.opacity(available ? 1 : 0.4))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(T4.ink.opacity(available ? 1 : 0.4))
                        T4Badge(text: mode.kind == .custom ? L("自定义", "Custom") : L("内置", "Built-in"))
                    }
                    Text(available ? mode.summary : L("需要先导入处理模型", "Import a text model first"))
                        .font(.system(size: 12))
                        .foregroundStyle(T4.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? T4.ink : T4.ink.opacity(0.2))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Recent dictation in one bordered list, like the Mac Home feed.
struct RecentCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L("最近说过的话", "Recent Dictation")) {
                if !history.entries.isEmpty {
                    Button(L("全部", "See All")) { model.tab = .history }
                        .buttonStyle(.glass)
                        .tint(T4.ink)
                        .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if history.entries.isEmpty {
                    Text(L("在任意 App 里切到 Type4Me 键盘，按住麦克风说一句试试。", "Switch to the Type4Me keyboard in any app, hold the mic and say something."))
                        .font(.system(size: 14))
                        .foregroundStyle(T4.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(history.entries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(T4.border) }
                        HistoryRow(entry: entry)
                    }
                }
            }
            .t4Card(padding: 16)
        }
    }
}

extension DictationMode {
    /// Same symbols as the Mac mode list.
    var symbol: String {
        switch kind {
        case .intelliSense: return "sparkles"
        case .quick: return "bolt"
        case .formalWriting: return "wand.and.stars"
        case .translation: return "character.book.closed"
        case .agentMode: return "paperplane"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// One-line description, worded like the Mac built-in modes. Custom
    /// modes show the start of their prompt.
    var summary: String {
        switch kind {
        case .intelliSense: return L("结合当前输入框的场景和上下文，智能整理口述内容", "Polishes dictation using the text field's scene and context")
        case .quick: return L("快速转写，不进行后处理", "Fast transcription, no post-processing")
        case .formalWriting: return L("将口语整理成清晰、可读的文字", "Turns speech into clear, readable writing")
        case .translation:
            let target = ModePrompts.translationTarget(of: self).displayName
            return L("自动识别口述语言，翻译为\(target)", "Detects the spoken language and translates it into \(target)")
        case .agentMode: return L("说出需求，直接生成可用成品", "Speak a request and get a ready-to-use result")
        case .custom:
            let prompt = definition?.prompt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return prompt.isEmpty ? L("自定义 Prompt", "Custom prompt") : prompt
        }
    }
}

/// One dictation. Tap to expand and see the original words.
struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.finalText)
                    .font(.system(size: 15))
                    .foregroundStyle(T4.ink)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = entry.finalText
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied ? T4.success : T4.secondary)
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("复制", "Copy"))
            }

            HStack(spacing: 6) {
                Text(entry.mode.title)
                Text("·")
                Text(entry.date, style: .time)
                if entry.delivered == .copied {
                    Text(L("· 已复制到剪贴板", "· Copied to clipboard"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(T4.tertiary)

            if expanded, entry.rawText != entry.finalText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("原话", "Original")).font(.system(size: 11, weight: .semibold)).foregroundStyle(T4.tertiary)
                    Text(entry.rawText).font(.system(size: 13)).foregroundStyle(T4.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(T4.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let note = entry.note {
                Text(note).font(.system(size: 12)).foregroundStyle(T4.amber)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @ObservedObject private var modes = ModeStore.shared
    @State private var query = ""
    @State private var filter: DictationMode?

    private var filtered: [HistoryEntry] {
        history.entries.filter { entry in
            (filter == nil || entry.mode == filter)
                && (query.isEmpty || entry.finalText.localizedCaseInsensitiveContains(query)
                    || entry.rawText.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Same page heading as Home, so the tabs read as one app.
                Text(L("历史", "History"))
                    .font(.system(size: 31, weight: .heavy))
                    .foregroundStyle(T4.ink)
                    .padding(.top, 6)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(T4.tertiary)
                    TextField(L("搜索说过的话", "Search your dictation"), text: $query)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(T4.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("清除搜索", "Clear search"))
                    }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(height: 44)
                // Glass as a sibling layer, not wrapping the field: content
                // inside glass gets its own appearance, which forced a light
                // keyboard in dark mode.
                .background { Color.clear.glassEffect(.regular, in: Capsule()) }
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            chip(L("全部", "All"), selected: filter == nil) { filter = nil }
                            ForEach(DictationMode.allModes) { mode in
                                chip(mode.title, selected: filter == mode) { filter = mode }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .scrollClipDisabled()
                if !filtered.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(T4.border) }
                            HistoryRow(entry: entry)
                        }
                    }
                    .t4Card(padding: 16)
                }
                if filtered.isEmpty {
                    Text(L("没有找到", "No matches")).foregroundStyle(T4.secondary).padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(DottedCanvas())
        .scrollDismissesKeyboard(.immediately)
        .safeAreaBar(edge: .top) { Color.clear.frame(height: 0) }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 16)
                .frame(height: 34)
                .foregroundStyle(selected ? T4.background : T4.ink)
                .glassEffect(selected ? .regular.tint(T4.ink).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Shown after the keyboard opened the app to start a session. iOS gives no
/// way to send the user back, so the page points at the system's "◀ App"
/// back link in the top-left corner and acts out the swipe along the home
/// bar. It closes itself once the user leaves.
struct SessionStartedView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top
            ZStack(alignment: .topLeading) {
                DottedCanvas()
                BackLinkPointer(statusBarHeight: top)
                    .ignoresSafeArea()
                content
                    .padding(.top, 96)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                HomeBarSwipeHint()
                    .ignoresSafeArea()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("点左上角\n回到刚才的 App", "Tap the top-left corner\nto go back"))
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(T4.ink)
                .accessibilityAddTraits(.isHeader)
            Text(L("回去后按住键盘上的麦克风说话。", "Then hold the mic on the keyboard to talk."))
                .font(.system(size: 17))
                .foregroundStyle(T4.secondary)
                .padding(.top, 12)
            HStack(spacing: 8) {
                LiquidGlassOrb(meter: session.meter, size: 18)
                Text(L("语音会话已开启", "Voice session on"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(T4.success)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(T4.success.opacity(0.14)))
            .padding(.top, 22)
            Spacer()
            VStack(spacing: 16) {
                Text(L("或者沿底部横条向右滑", "Or swipe right along the bar at the bottom"))
                    .font(.system(size: 14))
                    .foregroundStyle(T4.secondary)
                HStack(spacing: 20) {
                    Button(L("留在 Type4Me", "Stay in Type4Me")) { model.showsSessionStarted = false }
                    Button(L("关闭会话", "End Session")) {
                        session.endSession(reason: L("手动结束", "ended manually"))
                        model.showsSessionStarted = false
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(T4.tertiary)
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
        }
    }
}

/// A ring pulsing around where iOS draws "◀ App" in the status bar, with an
/// arrow swinging towards it.
private struct BackLinkPointer: View {
    let statusBarHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        // The back link sits at the left of the status bar, vertically
        // centred in it (a little low on Dynamic Island phones).
        let link = CGPoint(x: 46, y: max(22, statusBarHeight * 0.55))
        ZStack(alignment: .topLeading) {
            Capsule()
                .stroke(T4.success, lineWidth: 2)
                .frame(width: 80, height: 30)
                .scaleEffect(pulse ? 1.45 : 0.85)
                .opacity(pulse ? 0 : 0.9)
                .position(link)
            BackArrow()
                .stroke(T4.success, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: 92, height: 82)
                .offset(x: pulse ? -4 : 0, y: pulse ? -4 : 0)
                .position(x: link.x + 52, y: link.y + 58)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A curved arrow from bottom right to top left, head at the top left.
private struct BackArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tip = CGPoint(x: rect.minX + 6, y: rect.minY + 6)
        path.move(to: CGPoint(x: rect.maxX - 6, y: rect.maxY - 4))
        path.addQuadCurve(to: tip, control: CGPoint(x: rect.maxX - 18, y: rect.minY + 14))
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x + 18, y: tip.y - 2))
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x + 6, y: tip.y + 17))
        return path
    }
}

/// A dot sliding left to right along the home bar, acting out the swipe
/// that goes back to the previous app.
private struct HomeBarSwipeHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide = false

    var body: some View {
        Circle()
            .fill(T4.success.opacity(0.85))
            .frame(width: 18, height: 18)
            .offset(x: slide ? 60 : -60)
            .opacity(reduceMotion ? 0.85 : (slide ? 0 : 0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeIn(duration: 1.6).repeatForever(autoreverses: false)) { slide = true }
            }
    }
}

/// A newer build is out (`UpdateCheck`): open TestFlight or the App Store.
struct UpdateCard: View {
    let update: UpdateCheck.Available
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(T4.ink)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("新版本 \(update.version) 可以更新", "Version \(update.version) Is Available"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(T4.ink)
                    if let notes = update.notes {
                        Text(notes)
                            .font(.system(size: 13))
                            .foregroundStyle(T4.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(T4.secondary)
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("关闭", "Close"))
            }
            Link(destination: update.url) {
                Label(L("去更新", "Update"), systemImage: "arrow.up.forward.app")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T4.background)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.glassProminent)
            .tint(T4.ink)
        }
        .t4Card(padding: 18)
    }
}
