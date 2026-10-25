import AppKit
import SwiftUI

/// The sidebar's Mobile page: how to get Type4Me on iPhone, and the QR codes
/// that sync this Mac's setup over.
struct MobileAppPage: View, SettingsCardHelpers {
    /// The iPhone app isn't on the App Store yet; people build it themselves.
    static let sourceURL = URL(string: "https://github.com/joewongjc/type4me/tree/main/iOS")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: L("手机版", "MOBILE"),
                title: L("手机版", "Mobile"),
                description: L(
                    "在 iPhone 上用 Type4Me 键盘语音输入。识别服务、模型、模式和词汇可以从这台 Mac 同步过去。",
                    "Dictate with the Type4Me keyboard on iPhone. Speech services, models, modes and vocabulary can sync over from this Mac."
                )
            )

            VStack(alignment: .leading, spacing: 24) {
                downloadCard
                syncCard
            }
        }
    }

    private var downloadCard: some View {
        settingsGroupCard(L("下载手机版", "Get the mobile app"), icon: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(L(
                    "手机版还没有上架 App Store。代码已经开源在 GitHub，用这台 Mac 上的 Xcode 就能装到自己的 iPhone 上，步骤写在仓库 iOS 目录的说明里。",
                    "The mobile app isn't on the App Store yet. Its code is open source on GitHub, and you can install it on your own iPhone with Xcode on this Mac. The steps are in the README of the repository's iOS folder."
                ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsText)
                .fixedSize(horizontal: false, vertical: true)

                Text(L(
                    "需要 iOS 26 或更新版本的 iPhone，以及 Xcode 26 或更新版本。",
                    "Requires an iPhone on iOS 26 or later, and Xcode 26 or later."
                ))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)

                secondaryButton(L("在 GitHub 查看", "View on GitHub"), icon: "chevron.left.forwardslash.chevron.right") {
                    NSWorkspace.shared.open(Self.sourceURL)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var syncCard: some View {
        settingsGroupCard(L("同步配置到手机版", "Sync setup to the mobile app"), icon: "qrcode") {
            VStack(alignment: .leading, spacing: 14) {
                Text(L(
                    "选好要同步的内容，在手机版里打开「设置 › 扫码同步」对准这里。内容多时会拆成几张码自动轮播，手机扫齐所有码才算完成。",
                    "Pick what to sync, then open Settings › Scan to Sync in the mobile app and point it here. Larger selections are split into several codes that cycle automatically; the phone finishes once it has scanned them all."
                ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

                MobileSyncPanel()
            }
            .padding(.vertical, 12)
        }
    }
}
