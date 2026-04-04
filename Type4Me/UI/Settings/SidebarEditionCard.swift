import SwiftUI

struct EditionSwitchLink: View {
    @ObservedObject private var auth = CloudAuthManager.shared
    @State private var showSwitchConfirm = false
    @State private var showLoginAlert = false
    @AppStorage("tf_app_edition") private var editionRaw: String?

    private var edition: AppEdition? {
        editionRaw.flatMap { AppEdition(rawValue: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if switchTarget == .member && !auth.isLoggedIn {
                    showLoginAlert = true
                } else {
                    showSwitchConfirm = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: edition == .member ? "key.fill" : "person.crop.circle")
                        .font(.system(size: 10))
                    Text(switchTargetLabel)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                }
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .confirmationDialog(
            L("切换版本", "Switch Edition"),
            isPresented: $showSwitchConfirm,
            titleVisibility: .visible
        ) {
            Button(switchTargetLabel) { performSwitch() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(switchConfirmMessage)
        }
        .alert(
            L("请先登录", "Please log in first"),
            isPresented: $showLoginAlert
        ) {
            Button("OK") {}
        } message: {
            Text(L(
                "切换到官方会员需要先登录 Type4Me Cloud 账户。请在设置中登录后再试。",
                "Switching to Member requires a Type4Me Cloud account. Please log in first."
            ))
        }
    }

    // MARK: - Switch Logic

    private var switchTarget: AppEdition {
        edition == .member ? .byoKey : .member
    }

    private var switchTargetLabel: String {
        switchTarget == .member
            ? L("切换到官方会员", "Switch to Member")
            : L("切换到自带 API", "Switch to BYO API")
    }

    private var switchConfirmMessage: String {
        switchTarget == .member
            ? L("将使用 Type4Me Cloud 服务进行语音识别。", "Voice recognition will use Type4Me Cloud service.")
            : L("将使用你自己配置的 API 进行语音识别。", "Voice recognition will use your own configured API.")
    }

    private func performSwitch() {
        AppEditionMigration.switchTo(switchTarget)
    }
}
