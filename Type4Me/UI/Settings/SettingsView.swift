import SwiftUI

// MARK: - Navigation Item

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case askAnything
    case models
    case vocabulary
    case modes
    case history
    case preferences
    case appearance
    case about
    case debug
    #if HAS_CLOUD_SUBSCRIPTION
    case account
    #endif

    var id: String { rawValue }

    #if HAS_CLOUD_SUBSCRIPTION
    static func tabs(for edition: AppEdition?) -> [SettingsTab] {
        switch edition {
        case .member:
            return [.general, .askAnything, .modes, .vocabulary, .history, .preferences, .about]
        case .byoKey, .none:
            return [.general, .askAnything, .models, .vocabulary, .modes, .history, .preferences, .about]
        }
    }
    #endif

    var displayName: String {
        switch self {
        case .general:     return L("首页", "Home")
        case .askAnything: return L("随便问", "Ask Anything")
        case .models:      return L("模型", "Models")
        case .vocabulary:  return L("词汇", "Vocabulary")
        case .modes:       return L("模式", "Modes")
        case .history:     return L("历史", "History")
        case .preferences: return L("设置", "Settings")
        case .appearance:  return L("外观", "Appearance")
        case .about:       return L("关于", "About")
        case .debug:       return L("调试", "Debug")
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return L("账户", "Account")
        #endif
        }
    }

    var subtitle: String {
        switch self {
        case .general:    return L("模式与使用概览", "Modes & usage overview")
        case .askAnything: return L("历史问答与持续追问", "Past questions & follow-ups")
        case .models:      return L("语音识别与 LLM 引擎", "ASR & LLM engines")
        case .vocabulary:  return L("热词与片段替换", "Hotwords & snippets")
        case .modes:       return L("推理与默认行为", "Processing & defaults")
        case .history:     return L("会话与日志保留", "Sessions & logs")
        case .preferences: return L("偏好与系统权限", "Preferences & permissions")
        case .appearance:  return L("录音显示与文本输出", "Recording display & text output")
        case .about:       return L("版本、许可证与支持", "Version, license & support")
        case .debug:       return L("运行状态、日志与诊断", "Runtime, logs & diagnostics")
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return L("登录与订阅管理", "Login & subscription")
        #endif
        }
    }

    var icon: String {
        switch self {
        case .general:     return "house"
        case .askAnything: return "text.bubble"
        case .models:      return "cpu"
        case .vocabulary:  return "book.closed"
        case .modes:       return "slider.horizontal.3"
        case .history:     return "clock.arrow.circlepath"
        case .preferences: return "gearshape"
        case .appearance:  return "paintbrush"
        case .about:       return "questionmark.circle"
        case .debug:       return "ladybug"
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return "person.crop.circle"
        #endif
        }
    }
}

@MainActor
@Observable
final class AppNavigationModel {
    var selectedTab: SettingsTab = .general
    var pendingAskAnythingSessionID: UUID?
    var pendingModeSelectionID: UUID?
}

// MARK: - Settings View

struct SettingsView: View {

    private enum PendingTransition {
        case navigate(
            SettingsTab,
            beforeCommit: (() -> Void)? = nil,
            afterCommit: (() -> Void)? = nil
        )
        case closeWindow
    }

    @Environment(AppState.self) private var appState
    @Environment(AppNavigationModel.self) private var navigationModel
    @State private var hoveredTab: SettingsTab?
    @State private var draftCoordinator = SettingsDraftCoordinator()
    @State private var windowBox = WeakSettingsWindowBox()
    @State private var pendingTransition: PendingTransition?
    @State private var isContentMounted = false
    @State private var bypassNextCloseGuard = false
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @AppStorage(DebugSettingsAvailability.defaultsKey)
    private var debugPanelEnabled = DebugSettingsAvailability.defaultEnabled
    #if HAS_CLOUD_SUBSCRIPTION
    @State private var showDeviceConflict = false
    @AppStorage("tf_app_edition") private var editionRaw: String?
    private var edition: AppEdition? { editionRaw.flatMap { AppEdition(rawValue: $0) } }
    #endif

    private var selectedTab: SettingsTab {
        get { navigationModel.selectedTab }
        nonmutating set { navigationModel.selectedTab = newValue }
    }

    var body: some View {
        ZStack {
            TF.settingsWindowBackground
                .ignoresSafeArea()

            if isContentMounted {
                HStack(spacing: 0) {
                    sidebar
                        .overlay(alignment: .topLeading) {
                            WindowControlsCluster()
                                .frame(width: 54, height: 14)
                                .padding(.leading, 15)
                                .padding(.top, 15)
                        }
                        .padding(.leading, 10)
                        .padding(.vertical, 10)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    content
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .id(language)
        .frame(minWidth: 900, minHeight: 600)
        .coordinateSpace(name: "SettingsWindowCoordinateSpace")
        .overlay {
            SettingsTooltipRootHost()
        }
        .background(SettingsWindowConfigurator(
            windowBox: windowBox,
            onVisibilityChanged: { isVisible in
                isContentMounted = isVisible
            },
            onShouldClose: shouldCloseWindow
        ))
        .preferredColorScheme(.light)
        .alert(
            L("未保存的更改", "Unsaved Changes"),
            isPresented: Binding(
                get: { pendingTransition != nil },
                set: { if !$0 { pendingTransition = nil } }
            )
        ) {
            Button(L("保存", "Save")) {
                guard draftCoordinator.saveAll() else {
                    let transition = pendingTransition
                    pendingTransition = nil
                    DispatchQueue.main.async { pendingTransition = transition }
                    return
                }
                commitPendingTransition()
            }
            Button(L("放弃更改", "Discard"), role: .destructive) {
                draftCoordinator.discardAll()
                commitPendingTransition()
            }
            Button(L("取消", "Cancel"), role: .cancel) {
                pendingTransition = nil
            }
        } message: {
            Text(L("当前页面有未保存的更改。离开前要保存吗？",
                   "This page has unsaved changes. Save before leaving?"))
        }
        .onAppear {
            if VocabularyNavigationCenter.shared.hasPendingSettingsNavigation {
                requestNavigation(to: .vocabulary, afterCommit: {
                    VocabularyNavigationCenter.shared.consumeSettingsNavigation()
                })
            }
        }
        #if HAS_CLOUD_SUBSCRIPTION
        .onAppear {
            if (selectedTab == .models && edition == .member) ||
               (selectedTab == .account && edition != .member) {
                requestNavigation(to: .preferences)
            }
        }
        .onChange(of: editionRaw) { _, _ in
            if (selectedTab == .models && edition == .member) ||
               (selectedTab == .account && edition != .member) {
                requestNavigation(to: .preferences)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDeviceConflict)) { _ in
            showDeviceConflict = true
        }
        .alert(L("设备冲突", "Device Conflict"), isPresented: $showDeviceConflict) {
            Button(L("确定", "OK")) {
                if edition == .member { requestNavigation(to: .account) }
            }
        } message: {
            Text(L("你的账户已在其他设备登录，当前设备已自动登出。",
                    "Your account has been logged in on another device. This device has been signed out."))
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMode)) { note in
            let modeId = note.object as? UUID
            requestNavigation(to: .modes, beforeCommit: {
                navigationModel.pendingModeSelectionID = modeId
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHistory)) { _ in
            requestNavigation(to: .history)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToVocabulary)) { note in
            requestNavigation(to: .vocabulary, afterCommit: {
                if note.object is VocabularyNavigationRequest {
                    VocabularyNavigationCenter.shared.consumeSettingsNavigation()
                }
            })
        }
        .onChange(of: debugPanelEnabled) { _, isEnabled in
            if !isEnabled && selectedTab == .debug {
                requestNavigation(to: .preferences)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reserve the title-bar area for the native macOS window controls.
            Color.clear.frame(height: 54)

            // Brand
            HStack(spacing: 9) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text("Type4Me")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(TF.settingsText)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)

            // Nav items
            VStack(spacing: 4) {
                ForEach([SettingsTab.general, .askAnything, .vocabulary, .history]) { tab in
                    navItem(tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            if debugPanelEnabled {
                navItem(.debug)
                    .padding(.horizontal, 10)
            }
            #if HAS_CLOUD_SUBSCRIPTION
            if edition == .member {
                navItem(.account)
                    .padding(.horizontal, 10)
            }
            EditionSwitchLink()
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            #endif

            navItem(.preferences)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(width: 224)
        .background(
            // Floating card with a 10pt margin on top/left/bottom; rounded to
            // read like the window's own corner curvature (Apple Reminders).
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TF.settingsSidebar)
        )
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let isActive = tab == .preferences
            ? settingsSubtabs.contains(selectedTab)
            : selectedTab == tab
        let showBadge = tab == .preferences && appState.hasUnseenUpdate
        return Button {
            requestNavigation(to: tab)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isActive ? TF.settingsText : TF.settingsTextSecondary)
                    .frame(width: 20)
                Text(tab.displayName)
                    .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                if tab == .preferences {
                    Text(AppBuildInfo.current.compactLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }
                if showBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isActive
                            ? TF.settingsSidebarActive
                            : (hoveredTab == tab ? TF.settingsSidebarHover : .clear)
                    )
            )
        }
        .buttonStyle(SidebarNavButtonStyle())
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTab = isHovering ? tab : nil
            }
        }
    }

    // MARK: - Content

    private var settingsSubtabs: [SettingsTab] {
        #if HAS_CLOUD_SUBSCRIPTION
        if edition == .member {
            return [.preferences, .appearance, .modes, .about]
        }
        #endif
        return [.preferences, .appearance, .models, .modes, .about]
    }

    private var settingsSectionPicker: some View {
        LiquidGlassTabPicker(
            items: settingsSubtabs,
            selection: selectedTab,
            onSelectionChange: { requestNavigation(to: $0) }
        ) { tab, isSelected, _ in
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(tab == .preferences ? L("通用", "Generals") : tab.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                if tab == .about && appState.hasUnseenUpdate {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .fixedSize()
        .padding(.bottom, 24)
    }

    private var settingsHubHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "SETTINGS",
                title: L("设置", "Settings"),
                description: L("集中管理偏好、模型、处理模式与应用信息。", "Manage preferences, models, processing modes, and app information.")
            )
            settingsSectionPicker
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general:
            ZStack {
                HomeDottedWaveBackground()
                tabPage {
                    HomeDashboardView(isActive: selectedTab == .general) { modeId in
                        requestNavigation(to: .modes, beforeCommit: {
                            navigationModel.pendingModeSelectionID = modeId
                        })
                    }
                }
            }
        case .askAnything:
            fixedPage {
                AskAnythingPage(isActive: selectedTab == .askAnything)
            }
        case .vocabulary:
            fixedPage { VocabularyTab() }
        case .history:
            fixedPage { HistoryTab(isActive: selectedTab == .history) }
        case .preferences, .appearance, .models, .modes, .about:
            settingsHubPage
        case .debug:
            if debugPanelEnabled {
                tabPage { DebugSettingsTab() }
            } else {
                settingsHubPage
            }
            #if HAS_CLOUD_SUBSCRIPTION
        case .account:
            tabPage { AccountTab() }
            #endif
        }
    }

    /// Stable chrome for the four Settings subtabs. Keeping this outside the
    /// switched body prevents the “Settings” heading and description from
    /// being removed and inserted on every subtab selection.
    private var settingsHubPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHubHeader
                .padding(.horizontal, 38)
                .padding(.top, 34)
            settingsHubContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TF.settingsWindowBackground)
    }

    @ViewBuilder
    private var settingsHubContent: some View {
        switch selectedTab {
        case .preferences:
            settingsScrollableContent { GeneralSettingsTab(showsHeader: false) }
        case .appearance:
            settingsScrollableContent { AppearanceSettingsTab() }
        case .models:
            #if HAS_CLOUD_SUBSCRIPTION
            if edition != .member {
                settingsScrollableContent {
                    ModelSettingsTab(showsHeader: false, draftCoordinator: draftCoordinator)
                }
            } else {
                settingsScrollableContent { GeneralSettingsTab(showsHeader: false) }
            }
            #else
            settingsScrollableContent {
                ModelSettingsTab(showsHeader: false, draftCoordinator: draftCoordinator)
            }
            #endif
        case .modes:
            ModesSettingsTab(showsHeader: false, draftCoordinator: draftCoordinator)
                .padding(.horizontal, 38)
                .padding(.bottom, 34)
        case .about:
            settingsScrollableContent { AboutTab(showsHeader: false) }
        default:
            settingsScrollableContent { GeneralSettingsTab(showsHeader: false) }
        }
    }

    private func settingsScrollableContent<V: View>(
        @ViewBuilder content: () -> V
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
            .padding(.horizontal, 38)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scrollable tab page (most tabs).
    private func tabPage<V: View>(@ViewBuilder content: () -> V) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TF.settingsWindowBackground)
    }

    /// Fixed-height tab page (no outer scroll, content manages its own scroll).
    private func fixedPage<V: View>(@ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TF.settingsWindowBackground)
    }

    private func requestNavigation(
        to tab: SettingsTab,
        beforeCommit: (() -> Void)? = nil,
        afterCommit: (() -> Void)? = nil
    ) {
        guard tab != selectedTab else {
            beforeCommit?()
            afterCommit?()
            return
        }
        guard draftCoordinator.hasUnsavedChanges else {
            commitNavigation(to: tab, beforeCommit: beforeCommit, afterCommit: afterCommit)
            return
        }
        pendingTransition = .navigate(
            tab,
            beforeCommit: beforeCommit,
            afterCommit: afterCommit
        )
    }

    private func commitNavigation(
        to tab: SettingsTab,
        beforeCommit: (() -> Void)?,
        afterCommit: (() -> Void)?
    ) {
        beforeCommit?()
        selectedTab = tab
        if tab == .about {
            UpdateChecker.shared.markAsSeen(appState: appState)
        }
        if let afterCommit {
            DispatchQueue.main.async(execute: afterCommit)
        }
    }

    private func shouldCloseWindow() -> Bool {
        if bypassNextCloseGuard {
            bypassNextCloseGuard = false
            isContentMounted = false
            return true
        }
        guard draftCoordinator.hasUnsavedChanges else {
            isContentMounted = false
            return true
        }
        pendingTransition = .closeWindow
        return false
    }

    private func commitPendingTransition() {
        guard let transition = pendingTransition else { return }
        pendingTransition = nil
        switch transition {
        case .navigate(let tab, let beforeCommit, let afterCommit):
            commitNavigation(to: tab, beforeCommit: beforeCommit, afterCommit: afterCommit)
        case .closeWindow:
            bypassNextCloseGuard = true
            isContentMounted = false
            windowBox.window?.performClose(nil)
        }
    }
}

// MARK: - Window Chrome

/// Makes the title-bar area use the exact same solid canvas color as the page
/// and positions the real macOS controls within the inset sidebar card. Keeping
/// the native zoom button preserves macOS's hover tiling/full-screen menu.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    let windowBox: WeakSettingsWindowBox
    let onVisibilityChanged: @MainActor (Bool) -> Void
    let onShouldClose: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            windowBox: windowBox,
            onVisibilityChanged: onVisibilityChanged,
            onShouldClose: onShouldClose
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onVisibilityChanged = onVisibilityChanged
        context.coordinator.onShouldClose = onShouldClose
        configureWhenAttached(nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            coordinator.attach(to: window)
            window.isOpaque = true
            window.backgroundColor = NSColor(
                srgbRed: 1,
                green: 1,
                blue: 1,
                alpha: 1
            )
            window.titlebarAppearsTransparent = true
            // Only the native (transparent) title bar strip should move the window;
            // dragging elsewhere is reserved for in-content interactions like
            // reordering the mode list.
            window.isMovableByWindowBackground = false
            window.contentMinSize = NSSize(width: 900, height: 600)
            // The native traffic lights are hidden by `WindowControlsCluster`,
            // which draws fresh standard buttons at the desired inset inside
            // the sidebar card (see SettingsView body).
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let windowBox: WeakSettingsWindowBox
        var onVisibilityChanged: @MainActor (Bool) -> Void
        var onShouldClose: @MainActor () -> Bool
        private weak var previousDelegate: NSWindowDelegate?
        private weak var attachedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(
            windowBox: WeakSettingsWindowBox,
            onVisibilityChanged: @escaping @MainActor (Bool) -> Void,
            onShouldClose: @escaping @MainActor () -> Bool
        ) {
            self.windowBox = windowBox
            self.onVisibilityChanged = onVisibilityChanged
            self.onShouldClose = onShouldClose
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow) {
            windowBox.window = window
            guard attachedWindow !== window else {
                if window.delegate !== self {
                    previousDelegate = window.delegate
                    window.delegate = self
                }
                if window.isVisible { onVisibilityChanged(true) }
                return
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            attachedWindow = window
            if window.delegate !== self {
                previousDelegate = window.delegate
                window.delegate = self
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisibilityChanged(true) }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisibilityChanged(false) }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisibilityChanged(true) }
            })
            if window.isVisible { onVisibilityChanged(true) }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let attachedWindow, attachedWindow.delegate === self {
                attachedWindow.delegate = previousDelegate
            }
            attachedWindow = nil
            windowBox.window = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if previousDelegate?.windowShouldClose?(sender) == false { return false }
            return onShouldClose()
        }

        func windowWillClose(_ notification: Notification) {
            onVisibilityChanged(false)
            previousDelegate?.windowWillClose?(notification)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true {
                return previousDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }

}

/// Draws fresh standard macOS window buttons (close/miniaturize/zoom) at an
/// arbitrary position inside the content layer and hides the window's native
/// traffic lights, per Apple's documented approach for custom placement.
///
/// The buttons are created via `NSWindow.standardWindowButton(_:for:)` and wired
/// to `performClose(_:)` / `performMiniaturize(_:)` / `performZoom(_:)` through
/// the responder chain, so they behave exactly like the originals. Living in the
/// SwiftUI content hierarchy (not the fragile titlebar layer) keeps clicks and
/// hover glyphs reliable.
private struct WindowControlsCluster: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowControlsClusterView {
        WindowControlsClusterView()
    }

    func updateNSView(_ nsView: WindowControlsClusterView, context: Context) {
        nsView.hideNativeButtons()
    }
}

private final class WindowControlsClusterView: NSView {
    private static let style: NSWindow.StyleMask =
        [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    private static let spacing: CGFloat = 20
    private static let diameter: CGFloat = 14

    private let close: NSButton
    private let mini: NSButton
    private let zoom: NSButton
    private let glyphs: [WindowControlGlyphView]
    private var mouseInside = false {
        didSet {
            guard mouseInside != oldValue else { return }
            glyphs.forEach { $0.isHovered = mouseInside }
        }
    }

    override init(frame frameRect: NSRect) {
        close = NSWindow.standardWindowButton(.closeButton, for: Self.style) ?? NSButton()
        mini = NSWindow.standardWindowButton(.miniaturizeButton, for: Self.style) ?? NSButton()
        zoom = NSWindow.standardWindowButton(.zoomButton, for: Self.style) ?? NSButton()
        glyphs = [
            WindowControlGlyphView(symbolName: "xmark"),
            WindowControlGlyphView(symbolName: "minus"),
            WindowControlGlyphView(symbolName: "arrow.up.left.and.arrow.down.right")
        ]
        super.init(frame: frameRect)

        for button in [close, mini, zoom] {
            button.target = nil  // routed up the responder chain to the window
            addSubview(button)
        }
        glyphs.forEach(addSubview)
        close.action = #selector(NSWindow.performClose(_:))
        mini.action = #selector(NSWindow.performMiniaturize(_:))
        zoom.action = #selector(NSWindow.performZoom(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Flipped so button origins are measured from the top edge.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideNativeButtons()
    }

    /// Hide the window's real traffic lights so only our cluster is visible.
    func hideNativeButtons() {
        guard let window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        for (index, button) in [close, mini, zoom].enumerated() {
            let frame = NSRect(
                x: CGFloat(index) * Self.spacing,
                y: 0,
                width: Self.diameter,
                height: Self.diameter
            )
            button.frame = frame
            glyphs[index].frame = frame
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Pad the tracking region so the glyphs light up as the cursor
        // approaches the cluster, matching native traffic-light behavior.
        let region = bounds.insetBy(dx: -4, dy: -4)
        addTrackingArea(
            NSTrackingArea(
                rect: region,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
        )
        // Handle the case where the cursor is already inside when the tracking
        // area is (re)created — mouseEntered won't fire on its own then.
        if let window, window.isVisible {
            let pointInWindow = window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            mouseInside = region.contains(pointInView)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
    }
}

/// A visual-only overlay. Returning `nil` from hit-testing lets the native
/// window button underneath retain clicks, accessibility, and the zoom menu.
private final class WindowControlGlyphView: NSImageView {
    var isHovered = false {
        didSet { isHidden = !isHovered }
    }

    init(symbolName: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        imageScaling = .scaleProportionallyDown
        contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 0.78)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Reusable Components

struct SettingsSectionHeader: View {
    let label: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(TF.settingsText)
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
        .padding(.bottom, 24)
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    var statusColor: Color? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor ?? TF.settingsTextSecondary)
        }
        .padding(.vertical, 10)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.045))
            .frame(height: 1)
    }
}

private struct SidebarNavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.spring(response: 0.16, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
