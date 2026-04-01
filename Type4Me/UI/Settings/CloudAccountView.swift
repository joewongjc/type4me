import SwiftUI

// MARK: - Cloud Account View Model

@Observable @MainActor
final class CloudAccountViewModel {
    var isLoggedIn = false
    var userEmail: String?
    var plan: String = "free"  // "free" or "pro"
    var subscriptionActive = false
    var expiresAt: Date?
    var freeCharsRemaining: Int = 1000
    var isLoading = false
    var magicLinkSent = false
    var errorMessage: String?

    var isPro: Bool { plan == "pro" && subscriptionActive }
    var isCN: Bool { Locale.current.region?.identifier == "CN" }
    var priceText: String { isCN ? "¥5/周" : "$1/week" }

    func sendMagicLink(email: String) {
        guard !email.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await CloudAuthManager.shared.sendMagicLink(email: email)
                self.magicLinkSent = true
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func logout() {
        Task {
            try? await CloudAuthManager.shared.signOut()
        }
        isLoggedIn = false
        userEmail = nil
        plan = "free"
        subscriptionActive = false
        expiresAt = nil
        freeCharsRemaining = 1000
        magicLinkSent = false
    }

    func refreshState() {
        Task { @MainActor in
            let loggedIn = await CloudAuthManager.shared.isLoggedIn
            self.isLoggedIn = loggedIn
            if loggedIn {
                let session = await CloudAuthManager.shared.currentSession()
                self.userEmail = session?.userEmail
                if let sub = try? await CloudSubscriptionManager.shared.subscription() {
                    self.plan = sub.plan
                    self.subscriptionActive = sub.isActive
                    self.expiresAt = sub.expiresAt
                    self.freeCharsRemaining = sub.freeCharsRemaining ?? 0
                }
            }
        }
    }
}

// MARK: - Cloud Account View

struct CloudAccountView: View {

    @State private var viewModel = CloudAccountViewModel()
    @State private var email = ""
    @State private var showPricing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isLoggedIn {
                if viewModel.isPro {
                    proAccountSection
                } else {
                    freeAccountSection
                }
            } else {
                loginSection
            }
        }
        .onAppear { viewModel.refreshState() }
        .sheet(isPresented: $showPricing) {
            PricingView(
                currentPlan: viewModel.plan,
                onUpgrade: {
                    // TODO: Trigger payment flow (Paddle / Xunhupay)
                    showPricing = false
                },
                onSwitchToFree: {
                    showPricing = false
                }
            )
        }
    }

    // MARK: - Login Section

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Type4Me Cloud")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TF.settingsText)

                featureBullet(
                    icon: "bolt.fill",
                    text: L("登录即用，无需配置 API 密钥", "Login and go, no API keys needed")
                )
                featureBullet(
                    icon: "mic.fill",
                    text: L("专业语音模型，200ms 低延迟", "Pro ASR models, 200ms latency")
                )
                featureBullet(
                    icon: "gift.fill",
                    text: L("免费体验 1000 字", "1000 characters free trial")
                )
            }

            SettingsDivider()

            if viewModel.magicLinkSent {
                magicLinkSentView
            } else {
                emailInputSection
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsAccentRed)
            }
        }
        .padding(.vertical, 8)
    }

    private var emailInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("EMAIL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("输入邮箱地址", "Enter email address"), text: $email)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(TF.settingsCardAlt)
                    )
            }

            Button {
                viewModel.sendMagicLink(email: email)
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    Text(L("免费体验 · 发送登录链接", "Free Trial · Send Login Link"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsNavActive)
            )
            .disabled(email.isEmpty || viewModel.isLoading)
            .opacity(email.isEmpty ? 0.5 : 1.0)
        }
    }

    private var magicLinkSentView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(TF.settingsAccentGreen)
                Text(L("登录链接已发送", "Login Link Sent"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
            }

            Text(L("请检查邮箱并点击链接完成登录。", "Check your email and click the link to log in."))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextSecondary)

            Button {
                viewModel.magicLinkSent = false
            } label: {
                Text(L("重新发送", "Resend"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsAccentBlue)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Free Account Section

    private var freeAccountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let email = viewModel.userEmail {
                        Text(email)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                    }
                    Text(L("免费体验", "Free Trial"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Spacer()
                Button { viewModel.logout() } label: {
                    Text(L("退出", "Logout"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }

            SettingsDivider()

            // Free trial remaining
            HStack(spacing: 6) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextSecondary)
                Text(L("剩余免费额度: \(viewModel.freeCharsRemaining) 字",
                       "\(viewModel.freeCharsRemaining) characters remaining"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
            }

            SettingsDivider()

            // Upgrade CTA
            Button { showPricing = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                    Text(L("升级至 Pro · \(viewModel.priceText)", "Upgrade to Pro · \(viewModel.priceText)"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsNavActive)
            )
        }
        .padding(.vertical, 8)
    }

    // MARK: - Pro Account Section

    private var proAccountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let email = viewModel.userEmail {
                            Text(email)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TF.settingsText)
                        }
                        proBadge
                    }
                    if let expires = viewModel.expiresAt {
                        Text(L("下次续费: ", "Next renewal: ") + expires.formatted(.dateTime.year().month().day()))
                            .font(.system(size: 11))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                }
                Spacer()
                Button { viewModel.logout() } label: {
                    Text(L("退出", "Logout"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }

            SettingsDivider()

            // Status
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsAccentGreen)
                Text(L("不限时长，畅快使用", "Unlimited usage, enjoy!"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
            }

            SettingsDivider()

            Button {
                // TODO: Open subscription management URL
            } label: {
                HStack(spacing: 4) {
                    Text(L("管理订阅", "Manage Subscription"))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsAccentBlue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Shared Components

    private var proBadge: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Color(red: 0.45, green: 0.33, blue: 0.05))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color(red: 0.95, green: 0.85, blue: 0.50).opacity(0.6))
            )
    }

    private func featureBullet(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.settingsAccentAmber)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
        }
    }
}
