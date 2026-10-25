import AVFoundation
import SwiftUI
import Type4MeTransferCore

/// First-run guide: permissions (keyboard with Full Access, microphone) on one
/// page, then the Mac import, then a try-it page. The try-it field comes last
/// because dictating needs every earlier step to be done.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var step: Step = Self.initialStep
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var trialText = ""
    @FocusState private var trialFocused: Bool

    enum Step: Int, CaseIterable {
        case permissions, importConfig, tryIt
    }

    private static var initialStep: Step {
        #if DEBUG
        if let raw = DemoSeed.onboardingStep, let step = Step(rawValue: raw) { return step }
        #endif
        return .permissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            progress
            switch step {
            case .permissions: permissionsStep
            case .importConfig: importStep
            case .tryIt: tryItStep
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DottedCanvas())
        // Tapping anywhere outside the field puts the keyboard away.
        .contentShape(Rectangle())
        .onTapGesture { trialFocused = false }
        .animation(.easeInOut(duration: 0.2), value: step)
        .onChange(of: model.configVersion) { _, _ in
            if step == .importConfig, model.hasConfig { step = .tryIt }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings: pick up a microphone change made there.
            if phase == .active { micStatus = AVAudioApplication.shared.recordPermission }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? T4.ink : T4.ink.opacity(0.12))
                    .frame(width: 22, height: 5)
            }
            Text(L("第 \(step.rawValue + 1) 步，共 3 步", "Step \(step.rawValue + 1) of 3"))
                .font(.system(size: 13))
                .foregroundStyle(T4.secondary)
                .padding(.leading, 6)
        }
    }

    // MARK: 1 · Permissions

    private var permissionsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(
                    L("打开键盘和麦克风", "Turn On the Keyboard and Microphone"),
                    L("键盘负责出字，Type4Me App 负责录音和识别，两个都要打开。", "The keyboard types the text and the Type4Me app does the recording and recognition, so both need to be on.")
                )

                permissionCard(
                    symbol: "keyboard",
                    title: L("Type4Me 键盘", "Type4Me Keyboard"),
                    done: model.keyboardSeen,
                    doneText: L("已检测到", "Detected")
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        numbered(1, L("点下面的「前往设置」", "Tap Go to Settings below"))
                        Divider().overlay(T4.separator)
                        numbered(2, L("进入「键盘」，打开 Type4Me", "Tap Keyboards and turn on Type4Me"))
                        Divider().overlay(T4.separator)
                        numbered(3, L("打开「允许完全访问」", "Turn on Allow Full Access"))
                    }
                    Text(L(
                        "键盘自己不能用麦克风，要通过完全访问和 Type4Me App 通信。我们不记录你的键入；只有按住说话时，才会参考光标附近的文字调整措辞，可以在设置里关闭。",
                        "Keyboards can't use the microphone themselves, so Full Access lets the keyboard talk to the Type4Me app. We don't log what you type. It only looks at the text near the cursor while you hold to talk, and you can turn that off in Settings."
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(T4.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    Button(L("前往设置", "Go to Settings")) { openSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 8)
                }

                permissionCard(
                    symbol: "mic",
                    title: L("麦克风", "Microphone"),
                    done: micStatus == .granted,
                    doneText: L("已允许", "Allowed")
                ) {
                    Text(L(
                        "只在你按住键盘上的麦克风时录音，松手就停。打开过一次 Type4Me 之后，它会留在后台待命，不用每次跳回来。",
                        "Records only while you hold the mic on the keyboard, and stops when you let go. Once Type4Me has been opened, it waits in the background, so you don't need to come back each time."
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(T4.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    switch micStatus {
                    case .granted:
                        EmptyView()
                    case .denied:
                        Text(L("麦克风被拒绝了，需要到设置里打开。", "Microphone access was denied. Turn it on in Settings."))
                            .font(.system(size: 13))
                            .foregroundStyle(T4.recording)
                        Button(L("前往设置", "Go to Settings")) { openSettings() }
                            .buttonStyle(SecondaryButtonStyle())
                    default:
                        Button(L("允许麦克风", "Allow Microphone")) {
                            AVAudioApplication.requestRecordPermission { _ in
                                Task { @MainActor in micStatus = AVAudioApplication.shared.recordPermission }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button(L("下一步", "Next")) { step = .importConfig }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(micStatus != .granted)
                .opacity(micStatus == .granted ? 1 : 0.4)
                .padding(.top, 8)
        }
    }

    // MARK: 2 · Import

    private var importStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                L("从 Mac 同步配置", "Sync Your Setup from Mac"),
                L("把 Mac 上的识别服务和处理模型带过来，不用在手机上再填一遍 API Key。", "Bring over the speech service and text model from your Mac. No need to type your API keys again.")
            )

            VStack(alignment: .leading, spacing: 0) {
                numbered(1, L("在 Mac 版 Type4Me 打开「设置 › 模型 › 同步到 iPhone」", "In Type4Me on your Mac, open Settings › Models › Sync to iPhone"))
                Divider().overlay(T4.separator)
                numbered(2, L("点下面的「扫码同步」，对准 Mac 上的二维码", "Tap Scan to Sync below and point it at the code on your Mac"))
                Divider().overlay(T4.separator)
                numbered(3, L("码会自动轮播时保持对准，扫齐后选择要导入的内容", "If the codes cycle, keep pointing until all are in, then choose what to import"))
            }
            .padding(.horizontal, 16)
            .background(T4.card, in: RoundedRectangle(cornerRadius: T4.cornerCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: T4.cornerCard, style: .continuous).strokeBorder(T4.border, lineWidth: 1))

            if model.hasConfig {
                Label(L("已导入配置", "Setup imported"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(T4.success)
                    .font(.system(size: 15, weight: .semibold))
            }

            Spacer(minLength: 0)
            VStack(spacing: 10) {
                if !model.hasConfig {
                    Button {
                        model.showsScanner = true
                    } label: {
                        Label(L("扫码同步", "Scan to Sync"), systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button(model.hasConfig ? L("下一步", "Next") : L("稍后再导入", "Import Later")) { step = .tryIt }
                    .buttonStyle(model.hasConfig ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
            }
        }
    }

    // MARK: 3 · Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiquidGlassOrb(meter: model.session.meter, size: 72)
                .padding(.top, 4)
            header(
                L("试一试", "Try It"),
                model.hasConfig
                    ? L("点下面的输入框，按 🌐 切到 Type4Me，按住麦克风说一句，松手就出字。", "Tap the field below, press 🌐 to switch to Type4Me, then hold the mic and say something. Let go to insert it.")
                    : L("还没导入配置，现在说话识别不了。可以随时在首页的「从 Mac 同步」里导入。", "Nothing is imported yet, so speech can't be recognized. You can import anytime from Sync from Mac on the Home tab.")
            )

            HStack(spacing: 8) {
                Image(systemName: model.keyboardSeen ? "checkmark.circle.fill" : "keyboard")
                    .foregroundStyle(model.keyboardSeen ? T4.success : T4.tertiary)
                Text(model.keyboardSeen
                    ? L("已检测到 Type4Me 键盘", "Type4Me keyboard detected")
                    : L("切到 Type4Me 键盘后这里会打勾", "This checks off once you switch to the Type4Me keyboard"))
                    .font(.system(size: 14, weight: model.keyboardSeen ? .semibold : .regular))
                    .foregroundStyle(model.keyboardSeen ? T4.success : T4.secondary)
            }

            TextField(L("点这里调出键盘", "Tap here to bring up the keyboard"), text: $trialText, axis: .vertical)
                .focused($trialFocused)
                .lineLimit(3...6)
                .font(.system(size: 16))
                .padding(14)
                .background(T4.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(T4.border, lineWidth: 1))

            if trialFocused {
                Button {
                    trialFocused = false
                } label: {
                    Label(L("收起键盘", "Hide Keyboard"), systemImage: "keyboard.chevron.compact.down")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.glass)
                .tint(T4.ink)
                .accessibilityIdentifier("onboarding.hideKeyboard")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
            }

            Spacer(minLength: 0)
            Button(L("开始使用", "Get Started")) {
                trialFocused = false
                model.completeOnboarding()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .animation(.easeInOut(duration: 0.15), value: trialFocused)
        // The keyboard can close itself (its own hide key) without SwiftUI
        // focus noticing; keep the in-app button in step with it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            trialFocused = false
        }
        .onAppear { startSessionForTrial() }
    }

    /// The try-it field only works with a live session; normally it starts
    /// once onboarding is finished.
    private func startSessionForTrial() {
        guard model.hasConfig, micStatus == .granted, !model.session.isActive else { return }
        model.session.startSession(trigger: L("引导试用", "onboarding try-it"))
    }

    // MARK: Pieces

    private func permissionCard<Content: View>(
        symbol: String,
        title: String,
        done: Bool,
        doneText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(T4.ink)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(T4.ink)
                Spacer(minLength: 0)
                if done {
                    Label(doneText, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(T4.success)
                }
            }
            content()
        }
        .t4Card(padding: 16)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(T4.ink)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(T4.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(T4.background)
                .frame(width: 24, height: 24)
                .background(T4.ink, in: Circle())
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(T4.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Lets one call site switch between two button styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
