import SwiftUI

// MARK: - Pricing View

struct PricingView: View {

    let currentPlan: String  // "free" or "pro"
    let onUpgrade: () -> Void
    let onSwitchToFree: () -> Void

    private var isCN: Bool { Locale.current.region?.identifier == "CN" }
    private var priceText: String { isCN ? "¥5" : "$1" }
    private var currencyNote: String { isCN ? "¥5/周" : "$1/week" }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Text("TYPE4ME")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(L("选择你的方案", "Choose Your Plan"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(TF.settingsText)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // Pricing columns
            HStack(alignment: .top, spacing: 16) {
                basicColumn
                proColumn
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 520)
        .background(TF.settingsCard)
    }

    // MARK: - Basic Column

    private var basicColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Basic")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                Text(L("免费", "Free"))
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(TF.settingsText)
                Text(L("自行配置，灵活使用", "Self-configured, flexible"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.bottom, 16)

            if currentPlan == "free" {
                planButton(
                    title: L("你当前的套餐", "Current Plan"),
                    isPrimary: false,
                    isDisabled: true,
                    action: {}
                )
            } else {
                planButton(
                    title: L("切换到免费版", "Switch to Free"),
                    isPrimary: false,
                    isDisabled: false,
                    action: onSwitchToFree
                )
            }

            Spacer().frame(height: 20)
            SettingsDivider()
            Spacer().frame(height: 12)

            VStack(alignment: .leading, spacing: 10) {
                featureRow(icon: "mic.fill", text: L("本地语音模型", "Local ASR models"))
                featureRow(icon: "key.fill", text: L("主流厂商 API 密钥适配", "Major provider API key support"))

                Spacer().frame(height: 4)
                Text(L("高级功能（需配密钥）", "Advanced (API key required)").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.top, 4)

                featureRow(icon: "mic.badge.plus", text: L("自定义语音识别模型", "Custom ASR models"))
                featureRow(icon: "brain", text: L("自定义 LLM 润色模型", "Custom LLM polish models"))
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TF.settingsBg)
        )
    }

    // MARK: - Pro Column

    private var proColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Pro")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TF.settingsText)
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsAccentAmber)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(priceText)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(TF.settingsText)
                    Text("/" + L("周", "week"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                }

                Text(L("登录即用，省心省力", "Login and go, hassle-free"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.bottom, 16)

            if currentPlan == "pro" {
                planButton(
                    title: L("当前计划", "Current Plan"),
                    isPrimary: true,
                    isDisabled: true,
                    action: {}
                )
            } else {
                planButton(
                    title: L("升级至 Pro", "Upgrade to Pro"),
                    isPrimary: true,
                    isDisabled: false,
                    action: onUpgrade
                )
            }

            Spacer().frame(height: 20)
            SettingsDivider()
            Spacer().frame(height: 12)

            VStack(alignment: .leading, spacing: 10) {
                featureRow(
                    icon: "bolt.fill",
                    text: L("登录即用，无需密钥", "Login and go, no API key needed"),
                    tint: TF.settingsAccentAmber
                )
                featureRow(
                    icon: "mic.fill",
                    text: L("不限时长语音输入", "Unlimited voice input"),
                    subtitle: L("豆包 2.0 + Soniox v4", "Doubao 2.0 + Soniox v4")
                )
                featureRow(
                    icon: "text.book.closed.fill",
                    text: L("共享专业词表", "Shared professional vocabulary"),
                    subtitle: L("技术词汇持续优化", "Tech terms continuously improved")
                )
                featureRow(
                    icon: "location.fill",
                    text: L("就近节点，200ms 响应", "Nearby nodes, 200ms response")
                )
                featureRow(
                    icon: "flask.fill",
                    text: L("实验室功能抢先体验", "Early access to lab features")
                )
                featureRow(
                    icon: "headphones",
                    text: L("优先客服支持", "Priority support")
                )
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(TF.settingsAccentAmber.opacity(0.4), lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TF.settingsBg)
                )
        )
    }

    // MARK: - Feature Row

    private func featureRow(
        icon: String,
        text: String,
        subtitle: String? = nil,
        tint: Color = TF.settingsTextSecondary
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
                .offset(y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }
        }
    }

    // MARK: - Plan Button

    private func planButton(
        title: String,
        isPrimary: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isDisabled
                ? TF.settingsTextTertiary
                : (isPrimary ? .white : TF.settingsText)
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isDisabled
                        ? TF.settingsCardAlt
                        : (isPrimary ? TF.settingsNavActive : TF.settingsCardAlt)
                )
        )
        .disabled(isDisabled)
    }
}
