import SwiftUI
import AVFoundation
import ApplicationServices

struct SetupWizardView: View {

    @Environment(AppState.self) private var appState
    @Environment(PermissionGuideModel.self) private var permissionGuideModel
    @State private var step = 0
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    #if HAS_CLOUD_SUBSCRIPTION
    @State private var selectedEdition: AppEdition = .member
    private var isMember: Bool { selectedEdition == .member }
    private let totalSteps = 5
    #else
    private let totalSteps = 4
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
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
                stepContent
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

    // MARK: - Step Router

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        #if HAS_CLOUD_SUBSCRIPTION
        case 1: pathSelectionStep
        case 2:
            if isMember { loginStep } else { providerStep }
        case 3: permissionsStep
        #else
        case 1: providerStep
        case 2: permissionsStep
        #endif
        default: readyStep
        }
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

    #if HAS_CLOUD_SUBSCRIPTION
    // MARK: - Step 1 (Subscription): Path Selection

    private var pathSelectionStep: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 8) {
                Text(L("选择你的方式", "Choose your path"))
                    .font(.system(size: 18, weight: .semibold))
                Text(L("随时可以在设置里切换。", "You can switch anytime in Settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                pathCard(icon: "person.crop.circle.badge.checkmark",
                         title: L("官方会员", "Official Member"),
                         detail: L("无需配置，2000 字免费体验", "No setup needed, 2000 chars free"),
                         isSelected: isMember) { selectedEdition = .member }
                pathCard(icon: "key.fill",
                         title: L("自带 API", "Bring Your Own API"),
                         detail: L("使用你自己的 API Key", "Use your own API keys"),
                         isSelected: !isMember) { selectedEdition = .byoKey }
            }.frame(width: 500)
            Spacer()
            Button(L("下一步", "Next")) { step = 2 }
                .buttonStyle(.borderedProminent).tint(TF.amber).controlSize(.large).padding(.bottom, 36)
        }
    }

    private func pathCard(icon: String, title: String, detail: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 28)).foregroundStyle(isSelected ? TF.amber : .secondary)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(isSelected ? .primary : .secondary)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 180)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? TF.amber.opacity(0.08) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? TF.amber : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }

    // MARK: - Step 2 (Subscription): Login

    @State private var email = ""
    @State private var codeSent = false
    @State private var verificationCode = ""
    @State private var isLoading = false
    @State private var loginError: String?
    @State private var loginSuccess = false

    private var loginStep: some View {
        VStack(spacing: 24) {
            Spacer()
            if loginSuccess {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(TF.success)
                Text(L("2000 字免费额度已激活", "2000 free characters activated")).font(.system(size: 16, weight: .medium))
                Spacer()
                navigationFooter { step = 3 }
            } else if codeSent {
                VStack(spacing: 8) {
                    Text(L("输入验证码", "Enter Verification Code")).font(.system(size: 18, weight: .semibold))
                    Text(L("验证码已发送到 \(email)", "Code sent to \(email)")).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    TextField(L("验证码", "Verification Code"), text: $verificationCode)
                        .textFieldStyle(.roundedBorder).frame(width: 280).multilineTextAlignment(.center)
                    if let error = loginError { Text(error).font(.caption).foregroundStyle(.red) }
                    Button { verifyCode() } label: {
                        if isLoading { ProgressView().controlSize(.small).frame(width: 280) }
                        else { Text(L("验证", "Verify")).frame(width: 280) }
                    }.buttonStyle(.borderedProminent).tint(TF.amber).disabled(verificationCode.isEmpty || isLoading)
                    Button(L("重新发送", "Resend Code")) { sendCode() }
                        .buttonStyle(.plain).foregroundStyle(TF.amber).font(.caption).disabled(isLoading)
                }
                Spacer()
            } else {
                VStack(spacing: 8) {
                    Text(L("登录", "Sign In")).font(.system(size: 18, weight: .semibold))
                    Text(L("输入邮箱，获取验证码", "Enter your email to get a verification code")).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    TextField(L("邮箱地址", "Email Address"), text: $email)
                        .textFieldStyle(.roundedBorder).frame(width: 280).multilineTextAlignment(.center)
                    if let error = loginError { Text(error).font(.caption).foregroundStyle(.red) }
                    Button { sendCode() } label: {
                        if isLoading { ProgressView().controlSize(.small).frame(width: 280) }
                        else { Text(L("发送验证码", "Send Code")).frame(width: 280) }
                    }.buttonStyle(.borderedProminent).tint(TF.amber).disabled(email.isEmpty || isLoading)
                }
                Spacer()
            }
        }
    }

    private func sendCode() {
        isLoading = true; loginError = nil
        Task {
            do { try await CloudAuthManager.shared.sendCode(email: email); codeSent = true }
            catch { loginError = error.localizedDescription }
            isLoading = false
        }
    }

    private func verifyCode() {
        isLoading = true; loginError = nil
        Task {
            do { try await CloudAuthManager.shared.verify(email: email, code: verificationCode); loginSuccess = true }
            catch { loginError = error.localizedDescription }
            isLoading = false
        }
    }
    #endif

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            PermissionGuideView(model: permissionGuideModel, embedded: true)

            #if HAS_CLOUD_SUBSCRIPTION
            navigationFooter { step = 4 }
            #else
            navigationFooter { step = 3 }
            #endif
        }
        .onAppear { permissionGuideModel.refresh() }
    }

    // MARK: - Step 1: Provider + Credentials

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
                    var defaults: [String: String] = [:]
                    let fields = ASRProviderRegistry.configType(for: newProvider)?.credentialFields ?? []
                    for field in fields where !field.defaultValue.isEmpty {
                        defaults[field.key] = field.defaultValue
                    }
                    credentialValues = defaults
                }

                // Dynamic credential fields
                ForEach(currentFields) { field in
                    if !field.options.isEmpty {
                        Picker(field.label, selection: Binding(
                            get: { credentialValues[field.key] ?? field.defaultValue },
                            set: { credentialValues[field.key] = $0 }
                        )) {
                            ForEach(field.options, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                    } else if field.isSecure {
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
                #if HAS_CLOUD_SUBSCRIPTION
                let nextStep = 3
                #else
                let nextStep = 2
                #endif
                Button(L("跳过", "Skip")) { step = nextStep }
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
                    step = nextStep
                }
                    .buttonStyle(.borderedProminent)
                    .tint(TF.amber)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 36)
        }
    }

    // MARK: - Step 3: Ready

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
                #if HAS_CLOUD_SUBSCRIPTION
                AppEditionMigration.switchTo(selectedEdition)
                #endif
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

