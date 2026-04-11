import SwiftUI

struct CloudSettingsCard: View, SettingsCardHelpers {
    @ObservedObject private var auth = CloudAuthManager.shared
    @ObservedObject private var quota = CloudQuotaManager.shared
    @State private var email = ""
    @State private var codeSent = false
    @State private var verificationCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        settingsGroupCard(L("Type4Me Cloud", "Type4Me Cloud"), icon: "cloud.fill") {
            if auth.isLoggedIn {
                loggedInContent
            } else {
                loginContent
            }
        }
        .task {
            if auth.isLoggedIn {
                await quota.refresh(force: true)
            }
        }
    }

    // MARK: - Logged In

    @ViewBuilder
    private var loggedInContent: some View {
        // Account + status badge
        HStack {
            Text(L("账户", "Account"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Text(auth.userEmail ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            statusBadge
        }
        .padding(.vertical, 10)

        SettingsDivider()

        // Plan & quota
        if quota.isPaid {
            SettingsRow(label: L("套餐", "Plan"), value: L("周订阅", "Weekly"), statusColor: .green)
            if let exp = quota.expiresAt {
                SettingsRow(label: L("到期", "Expires"), value: formatDate(exp))
            }
        } else {
            SettingsRow(label: L("套餐", "Plan"), value: L("免费", "Free"))
            HStack {
                Text(L("剩余字数", "Remaining"))
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Text("\(quota.freeCharsRemaining) / 2000")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(quota.freeCharsRemaining > 500 ? TF.settingsTextSecondary : .orange)
            }
            .padding(.vertical, 10)
        }

        SettingsDivider()

        // Usage stats
        SettingsRow(
            label: L("本周用量", "This week"),
            value: "\(quota.weekChars) " + L("字", "chars")
        )
        SettingsRow(
            label: L("总计", "Total"),
            value: "\(quota.totalChars) " + L("字", "chars")
        )

        SettingsDivider()

        // Region
        HStack {
            Text(L("区域", "Region"))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Picker("", selection: Binding(
                get: { CloudConfig.currentRegion },
                set: { CloudConfig.currentRegion = $0 }
            )) {
                Text(L("海外", "Overseas")).tag(CloudRegion.overseas)
                Text(L("中国大陆", "China")).tag(CloudRegion.cn)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.vertical, 6)

        SettingsDivider()

        // Actions
        HStack(spacing: 12) {
            if !quota.isPaid {
                let priceLabel = CloudConfig.currentRegion == .cn
                    ? CloudConfig.weeklyPriceCN
                    : CloudConfig.weeklyPriceUS
                primaryButton(L("订阅 \(priceLabel)/周", "Subscribe \(priceLabel)/wk")) {
                    // TODO: Open payment page (Paddle or LemonSqueezy)
                }
            }
            Spacer()
            Button(L("登出", "Log out")) {
                Task { await auth.signOut() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.settingsAccentRed)
        }
        .padding(.top, 4)
    }

    // MARK: - Login

    @ViewBuilder
    private var loginContent: some View {
        Text(L(
            "登录后即可使用 Type4Me Cloud 语音识别和文本处理服务。免费体验 2000 字。",
            "Sign in to use Type4Me Cloud for voice recognition and text processing. 2000 characters free."
        ))
        .font(.system(size: 12))
        .foregroundStyle(TF.settingsTextTertiary)
        .padding(.bottom, 4)

        if codeSent {
            // Code input + verify
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.badge")
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L(
                        "验证码已发送到 \(email)",
                        "Code sent to \(email)"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                }

                HStack(spacing: 8) {
                    FixedWidthTextField(
                        text: $verificationCode,
                        placeholder: L("6 位验证码", "6-digit code")
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(maxWidth: 160)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                    primaryButton(
                        isLoading
                            ? L("验证中...", "Verifying...")
                            : L("验证", "Verify")
                    ) {
                        verifyCode()
                    }
                    .disabled(verificationCode.isEmpty || isLoading)

                    Button(L("重新发送", "Resend")) {
                        sendCode()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            // Email input + send code
            HStack(spacing: 8) {
                FixedWidthTextField(
                    text: $email,
                    placeholder: L("邮箱", "Email")
                )
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: 260)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

                primaryButton(
                    isLoading
                        ? L("发送中...", "Sending...")
                        : L("发送验证码", "Send code")
                ) {
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

    // MARK: - Components

    private var statusBadge: some View {
        Text(quota.isPaid ? L("已订阅", "Subscribed") : L("免费", "Free"))
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    quota.isPaid
                        ? TF.settingsAccentGreen.opacity(0.15)
                        : Color.orange.opacity(0.15)
                )
            )
            .foregroundStyle(quota.isPaid ? TF.settingsAccentGreen : .orange)
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

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}
