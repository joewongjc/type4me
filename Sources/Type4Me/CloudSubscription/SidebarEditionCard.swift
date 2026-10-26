import SwiftUI

struct EditionSwitchLink: View {
    @AppStorage("tf_app_edition") private var editionRaw: String?

    private var edition: AppEdition? {
        editionRaw.flatMap { AppEdition(rawValue: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                performSwitch()
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

    private func performSwitch() {
        AppEditionMigration.switchTo(switchTarget)
    }
}
