import Foundation

/// App Review 5.1.2(i): before speech or text leaves the iPhone for a
/// third-party AI service, name the service and get the user's OK.
///
/// Agreement is kept per service (`asr:volcano`, `llm:deepseek`, …), so
/// switching to a service the user hasn't agreed to asks again, while
/// switching back to one already agreed to doesn't.
enum AIConsent {
    struct Recipient: Hashable {
        let key: String
        let name: String
        let receives: String
    }

    /// The services dictation would send data to right now.
    static var recipients: [Recipient] {
        var result: [Recipient] = []
        if let asr = ConfigStore.asr, asr.provider == ASRProvider.apple.rawValue {
            result.append(Recipient(
                key: "asr:\(asr.provider)",
                name: ProviderNames.asr(asr.provider),
                receives: L(
                    "你按住说话时录下的声音。所选语言支持时只在这台 iPhone 上识别，否则由 Apple 的服务器识别",
                    "The audio recorded while you hold to talk. It stays on this iPhone when the language supports on-device recognition; otherwise Apple's servers recognize it"
                )
            ))
        } else if let asr = ConfigStore.asr {
            result.append(Recipient(
                key: "asr:\(asr.provider)",
                name: ProviderNames.asr(asr.provider),
                receives: L("你按住说话时录下的声音和你设置的热词", "The audio recorded while you hold to talk, plus your hotwords")
            ))
        }
        // The on-device model keeps text on this iPhone, so there is nothing to agree to.
        if let llm = ConfigStore.llm, llm.provider != OnDeviceModel.providerID {
            result.append(Recipient(
                key: "llm:\(llm.provider)",
                name: ProviderNames.llm(llm.provider),
                receives: L(
                    "识别出的文字（仅限润色、翻译等使用文本模型的模式）",
                    "The recognized text (only in modes that use a text model, such as Voice Polish and Translate)"
                )
            ))
        }
        return result
    }

    static var isGranted: Bool {
        let agreed = AppSettings.aiConsentKeys
        return recipients.allSatisfy { agreed.contains($0.key) }
    }

    static func grant() {
        AppSettings.aiConsentKeys.formUnion(recipients.map(\.key))
    }

    static func revokeAll() {
        AppSettings.aiConsentKeys = []
    }
}
