import SwiftUI

struct AccountTab: View, SettingsCardHelpers {
    @ObservedObject private var auth = CloudAuthManager.shared
    @ObservedObject private var quota = CloudQuotaManager.shared

    // Email login state
    @State private var email = ""
    @State private var codeSent = false
    @State private var verificationCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Anonymous login state
    @State private var anonUsername = ""
    @State private var anonPassword = ""
    @State private var anonIsLogin = false
    @State private var anonLoading = false
    @State private var anonError: String?

    // Billing state
    @State private var billingRecords: [BillingRecord] = []
    @State private var billingLoading = false
    @State private var billingError: String?

    // MARK: - BillingRecord

    struct BillingRecord: Decodable, Identifiable {
        let id: Int
        let amount: Int       // cents
        let currency: String
        let status: String
        let description: String?
        let created_at: String // ISO8601
    }

    var body: some View {
        if auth.isLoggedIn {
            loggedInView
                .task { await loadLoggedInData() }
        } else {
            loginView
        }
    }

    // MARK: - Login View

    @ViewBuilder
    private var loginView: some View {
        SettingsSectionHeader(
            label: "ACCOUNT",
            title: L("账户", "Account"),
            description: L(
                "登录后即可使用 Type4Me Cloud 语音识别和文本处理服务。",
                "Sign in to use Type4Me Cloud voice recognition and text processing."
            )
        )

        emailLoginCard

        Spacer().frame(height: 16)

        anonymousLoginCard
    }

    // MARK: - Email Login Card

    private var emailLoginCard: some View {
        settingsGroupCard(L("邮箱登录", "Email Login"), icon: "envelope.fill") {
            if codeSent {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.badge")
                            .foregroundStyle(TF.settingsAccentGreen)
                        Text(L("验证码已发送到 \(email)", "Code sent to \(email)"))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }

                    HStack(spacing: 8) {
                        FixedWidthTextField(text: $verificationCode, placeholder: L("6 位验证码", "6-digit code"))
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .frame(maxWidth: 160)
                            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                        primaryButton(isLoading ? L("验证中...", "Verifying...") : L("验证", "Verify")) {
                            verifyCode()
                        }
                        .disabled(verificationCode.isEmpty || isLoading)

                        Button(L("重新发送", "Resend")) { sendCode() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text(L(
                    "免费体验 2000 字。",
                    "2000 characters free."
                ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 4)

                HStack(spacing: 8) {
                    FixedWidthTextField(text: $email, placeholder: L("邮箱", "Email"))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: 260)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                    primaryButton(isLoading ? L("发送中...", "Sending...") : L("发送验证码", "Send code")) {
                        sendCode()
                    }
                    .disabled(email.isEmpty || isLoading)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsAccentRed)
            }
        }
    }

    // MARK: - Anonymous Login Card

    private var anonymousLoginCard: some View {
        settingsGroupCard(L("匿名模式", "Anonymous Mode"), icon: "person.fill.questionmark") {
            Text(L(
                "不想提供邮箱？设置用户名和密码即可使用。",
                "Don't want to use email? Set a username and password."
            ))
            .font(.system(size: 12))
            .foregroundStyle(TF.settingsTextTertiary)
            .padding(.bottom, 4)

            HStack(spacing: 12) {
                Button(L("注册新账户", "Register")) {
                    anonIsLogin = false
                    anonError = nil
                }
                .foregroundStyle(anonIsLogin ? TF.settingsTextSecondary : TF.settingsText)

                Button(L("已有账户", "Log in")) {
                    anonIsLogin = true
                    anonError = nil
                }
                .foregroundStyle(anonIsLogin ? TF.settingsText : TF.settingsTextSecondary)
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            HStack(spacing: 8) {
                FixedWidthTextField(text: $anonUsername, placeholder: L("用户名", "Username"))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(maxWidth: 160)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                FixedWidthSecureField(text: $anonPassword, placeholder: L("密码 (至少6位)", "Password (6+ chars)"))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(maxWidth: 200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                primaryButton(
                    anonLoading
                        ? L("请等待...", "Please wait...")
                        : anonIsLogin ? L("登录", "Log in") : L("注册", "Register")
                ) {
                    anonIsLogin ? loginAnonymous() : registerAnonymous()
                }
                .disabled(anonUsername.isEmpty || anonPassword.count < 6 || anonLoading)
            }

            if let error = anonError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsAccentRed)
            }
        }
    }

    // MARK: - Actions

    private func sendCode() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await auth.sendCode(email: email)
                codeSent = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func verifyCode() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await auth.verify(email: email, code: verificationCode)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func registerAnonymous() {
        anonLoading = true
        anonError = nil
        Task {
            do {
                try await auth.registerAnonymous(username: anonUsername, password: anonPassword)
            } catch CloudAPIError.usernameTaken {
                anonError = L("用户名已被占用", "Username already exists")
            } catch {
                anonError = error.localizedDescription
            }
            anonLoading = false
        }
    }

    private func loginAnonymous() {
        anonLoading = true
        anonError = nil
        Task {
            do {
                try await auth.loginWithPassword(username: anonUsername, password: anonPassword)
            } catch {
                anonError = error.localizedDescription
            }
            anonLoading = false
        }
    }

    // MARK: - Logged In View

    @ViewBuilder
    private var loggedInView: some View {
        SettingsSectionHeader(
            label: "ACCOUNT",
            title: L("账户", "Account"),
            description: ""
        )

        profileCard
        Spacer().frame(height: 16)
        subscriptionCard
        Spacer().frame(height: 16)
        usageCard
        Spacer().frame(height: 16)
        billingCard
        Spacer().frame(height: 16)

        Button(L("登出", "Log out")) {
            Task { await auth.signOut() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(TF.settingsAccentRed)
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        settingsGroupCard(L("个人信息", "Profile"), icon: "person.fill") {
            HStack(spacing: 12) {
                // Avatar circle
                let initial = String((auth.userEmail ?? auth.username ?? "?").prefix(1)).uppercased()
                Text(initial)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(TF.settingsNavActive))

                VStack(alignment: .leading, spacing: 4) {
                    Text(auth.userEmail ?? auth.username ?? "—")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TF.settingsText)

                    // Status badge
                    Text(quota.isPaid ? L("已订阅", "Subscribed") : L("免费", "Free"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(quota.isPaid ? TF.settingsAccentGreen : TF.settingsAccentAmber)
                        )
                }

                Spacer()
            }

            // Anonymous user warning
            if auth.loginMethod == .anonymous && auth.userEmail == nil {
                SettingsDivider()

                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentAmber)
                    Text(L(
                        "请牢记用户名和密码，未绑定邮箱将无法找回",
                        "Remember your username and password. Without a linked email, account recovery is not possible."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsAccentAmber)
                }
                .padding(.top, 4)

                // TODO: bind email flow
                primaryButton(L("绑定邮箱", "Link Email")) {
                    // TODO: implement email binding
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Subscription Card

    private var subscriptionCard: some View {
        settingsGroupCard(L("订阅", "Subscription"), icon: "creditcard.fill") {
            if quota.isPaid {
                SettingsRow(
                    label: L("方案", "Plan"),
                    value: L("周订阅", "Weekly"),
                    statusColor: TF.settingsAccentGreen
                )
                if let expires = quota.expiresAt {
                    SettingsDivider()
                    SettingsRow(
                        label: L("到期时间", "Expires"),
                        value: formatDate(expires)
                    )
                }
            } else {
                SettingsRow(
                    label: L("方案", "Plan"),
                    value: L("免费", "Free")
                )
                SettingsDivider()
                SettingsRow(
                    label: L("剩余字符", "Remaining"),
                    value: "\(quota.freeCharsRemaining) / 2000",
                    statusColor: quota.freeCharsRemaining < 500 ? TF.settingsAccentAmber : nil
                )
                SettingsDivider()

                let price = CloudConfig.currentRegion == .cn
                    ? CloudConfig.weeklyPriceCN
                    : CloudConfig.weeklyPriceUS
                primaryButton(L("订阅 \(price)/周", "Subscribe \(price)/week")) {
                    // TODO: implement subscription purchase
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Usage Card

    private var usageCard: some View {
        settingsGroupCard(L("用量", "Usage"), icon: "chart.bar.fill") {
            SettingsRow(
                label: L("本周用量", "This week"),
                value: L("\(quota.weekChars) 字符", "\(quota.weekChars) chars")
            )
            SettingsDivider()
            SettingsRow(
                label: L("累计用量", "Total"),
                value: L("\(quota.totalChars) 字符", "\(quota.totalChars) chars")
            )
        }
    }

    // MARK: - Billing Card

    private var billingCard: some View {
        settingsGroupCard(L("账单记录", "Billing History"), icon: "doc.text.fill") {
            if billingLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if let error = billingError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentRed)
                    secondaryButton(L("重试", "Retry")) {
                        Task { await fetchBilling() }
                    }
                }
            } else if billingRecords.isEmpty {
                Text(L("暂无账单记录", "No billing records"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(billingRecords.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { SettingsDivider() }
                    HStack {
                        Text(formatBillingDate(record.created_at))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextSecondary)
                        Spacer()
                        if let desc = record.description {
                            Text(desc)
                                .font(.system(size: 12))
                                .foregroundStyle(TF.settingsTextSecondary)
                            Spacer()
                        }
                        Text(formatAmount(record.amount, currency: record.currency))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadLoggedInData() async {
        await quota.refresh(force: true)
        await fetchBilling()
    }

    private func fetchBilling() async {
        billingLoading = true
        billingError = nil
        do {
            let data = try await CloudAPIClient.shared.request("/api/billing/history")
            billingRecords = try JSONDecoder().decode([BillingRecord].self, from: data)
        } catch {
            billingError = error.localizedDescription
        }
        billingLoading = false
    }

    // MARK: - Formatters

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    private func formatBillingDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: date)
    }

    private func formatAmount(_ cents: Int, currency: String) -> String {
        let amount = Double(cents) / 100.0
        return currency == "CNY"
            ? "¥\(String(format: "%.2f", amount))"
            : "$\(String(format: "%.2f", amount))"
    }
}
