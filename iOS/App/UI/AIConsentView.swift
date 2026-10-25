import SwiftUI

enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/joewongjc/type4me/blob/main/docs/legal/ios-privacy.md")!
    static let support = URL(string: "https://github.com/joewongjc/type4me/issues")!
}

/// Names the third-party services dictation sends data to and asks before
/// the first use of each (`AIConsent`).
struct AIConsentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "hand.raised")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(T4.ink)
                .padding(.top, 8)
            Text(L("发送到第三方 AI 服务", "Sending to Third-Party AI Services"))
                .font(.system(size: 26, weight: .heavy))
            Text(L(
                "Type4Me 没有自己的服务器。听写时，下面这些你自己配置的服务会收到数据，由它们按各自的隐私政策处理：",
                "Type4Me has no servers of its own. When you dictate, the services you set up below receive data and handle it under their own privacy policies:"
            ))
            .font(.system(size: 15))
            .foregroundStyle(T4.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(AIConsent.recipients, id: \.self) { recipient in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recipient.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(T4.ink)
                        Text(recipient.receives)
                            .font(.system(size: 14))
                            .foregroundStyle(T4.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .t4Card()

            Text(L(
                "历史记录只存在这台 iPhone 上。可以随时在「设置」里撤回授权。",
                "History stays on this iPhone. You can withdraw this anytime in Settings."
            ))
            .font(.system(size: 13))
            .foregroundStyle(T4.tertiary)
            Link(L("隐私政策", "Privacy Policy"), destination: AppLinks.privacyPolicy)
                .font(.system(size: 14, weight: .medium))

            Spacer(minLength: 0)
            Button(L("同意并继续", "Agree and Continue")) { model.answerAIConsent(agreed: true) }
                .buttonStyle(PrimaryButtonStyle())
            Button(L("暂不", "Not Now")) { model.answerAIConsent(agreed: false) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
        .background(DottedCanvas())
    }
}
