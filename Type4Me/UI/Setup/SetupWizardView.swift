import SwiftUI
import AVFoundation
import ApplicationServices

struct SetupWizardView: View {

    @Environment(AppState.self) private var appState
    @State private var step = 0
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? TF.amber : Color.secondary.opacity(0.15))
                        .frame(height: 3)
                        .animation(.easeInOut(duration: 0.3), value: step)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 24)
            .padding(.bottom, 8)

            // Steps
            Group {
                switch step {
                case 0: welcomeStep
                case 1:
                    VStack(spacing: 0) {
                        QuickModeDemoStep()
                        navigationFooter { step = 2 }
                    }
                case 2:
                    VStack(spacing: 0) {
                        CustomModeDemoStep()
                        navigationFooter { step = 3 }
                    }
                case 3: permissionsStep
                case 4: providerStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(TF.springGentle, value: step)
        }
        .frame(width: 750, height: 520)
        .id(language)
    }

    // MARK: - Navigation Footer

    private func navigationFooter(action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(L("下一步", "Next"), action: action)
                .buttonStyle(.borderedProminent)
                .tint(TF.amber)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 36)
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(TF.amber.opacity(0.1))
                    .frame(width: 96, height: 96)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 42))
                    .foregroundStyle(TF.amber)
            }

            VStack(spacing: 8) {
                Text("Type4Me")
                    .font(.system(size: 24, weight: .bold))
                Text(L("说话，就是输入", "Speak, and it types"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Spacer()

            Button(L("开始设置", "Get Started")) { step = 1 }
                .buttonStyle(.borderedProminent)
                .tint(TF.amber)
                .controlSize(.large)
                .padding(.bottom, 36)
        }
    }

    // MARK: - Step 3: Permissions

    @State private var hasMic = false
    @State private var hasAccessibility = false

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(L("授予权限", "Grant Permissions"))
                .font(.system(size: 18, weight: .semibold))

            VStack(spacing: 14) {
                SetupPermissionCard(
                    icon: "mic.fill",
                    title: L("麦克风", "Microphone"),
                    detail: L("录制语音进行转写", "Record voice for transcription"),
                    granted: hasMic
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in hasMic = granted }
                    }
                }

                SetupPermissionCard(
                    icon: "accessibility",
                    title: L("辅助功能", "Accessibility"),
                    detail: L("全局快捷键 + 文字注入", "Global hotkeys + text injection"),
                    granted: hasAccessibility
                ) {
                    // Register in system list AND open system preferences
                    PermissionManager.promptAccessibilityPermission()
                    PermissionManager.openAccessibilitySettings()
                }
            }
            .frame(width: 340)

            Spacer()

            navigationFooter { step = 4 }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    // MARK: - Step 4: Provider + Credentials

    @State private var selectedProvider: ASRProvider = .volcano
    @State private var credentialValues: [String: String] = [:]

    private var currentFields: [CredentialField] {
        ASRProviderRegistry.configType(for: selectedProvider)?.credentialFields ?? []
    }

    private var hasRequiredFields: Bool {
        currentFields.filter { !$0.isOptional }.allSatisfy { field in
            let val = credentialValues[field.key] ?? ""
            return !val.isEmpty
        }
    }

    private var providerCapabilitySummary: String {
        ASRProviderRegistry.supportedModesSummary(for: selectedProvider)
    }

    private var providerStep: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text(L("配置语音识别", "Configure ASR"))
                    .font(.system(size: 18, weight: .semibold))
                Text(L("选择识别引擎并填写 API 凭据", "Choose an ASR engine and enter API credentials"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                // Provider picker
                Picker(L("识别引擎", "ASR Engine"), selection: $selectedProvider) {
                    ForEach(ASRProvider.allCases.filter {
                        ASRProviderRegistry.entry(for: $0)?.isAvailable ?? false
                    }, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: selectedProvider) { _, newProvider in
                    // Prefill defaults
                    var defaults: [String: String] = [:]
                    let fields = ASRProviderRegistry.configType(for: newProvider)?.credentialFields ?? []
                    for field in fields where !field.defaultValue.isEmpty {
                        defaults[field.key] = field.defaultValue
                    }
                    credentialValues = defaults
                }

                Text(providerCapabilitySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 300, alignment: .leading)

                // Dynamic credential fields
                ForEach(currentFields) { field in
                    if field.isSecure {
                        SecureField(field.label, text: Binding(
                            get: { credentialValues[field.key] ?? "" },
                            set: { credentialValues[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else if !field.isOptional {
                        TextField(field.label, text: Binding(
                            get: { credentialValues[field.key] ?? "" },
                            set: { credentialValues[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .frame(width: 300)

            Spacer()

            HStack {
                Button(L("跳过", "Skip")) { step = 5 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("下一步", "Next")) {
                    if hasRequiredFields {
                        try? KeychainService.saveASRCredentials(
                            for: selectedProvider, values: credentialValues
                        )
                        KeychainService.selectedASRProvider = selectedProvider
                    }
                    step = 5
                }
                    .buttonStyle(.borderedProminent)
                    .tint(TF.amber)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 36)
        }
    }

    // MARK: - Step 5: Ready

    private var readyStep: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(TF.success)

            VStack(spacing: 8) {
                Text(L("准备就绪", "Ready"))
                    .font(.system(size: 22, weight: .semibold))
                Text(L("按住右 Option 键开始说话\n松开后文字自动输入到光标位置", "Hold Right Option to speak\nText is typed at cursor on release"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Spacer()

            Button(L("开始使用", "Start Using")) {
                appState.hasCompletedSetup = true
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .tint(TF.amber)
            .controlSize(.large)
            .padding(.bottom, 36)
        }
    }
}

// MARK: - Permission Card

private struct SetupPermissionCard: View {

    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: TF.spacingMD) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 32)
                .foregroundStyle(granted ? TF.success : TF.amber)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(TF.success)
            } else {
                Button(L("授权", "Grant")) { action() }
                    .controlSize(.small)
            }
        }
        .padding(TF.spacingMD)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: TF.cornerSM))
    }
}
