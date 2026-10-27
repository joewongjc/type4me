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
        if let asr = ConfigStore.asr {
            result.append(Recipient(
                key: "asr:\(asr.provider)",
                name: ProviderNames.asr(asr.provider),
                receives: L("你按住说话时录下的声音和你设置的热词", "The audio recorded while you hold to talk, plus your hotwords")
            ))
        }
        if let llm = ConfigStore.llm {
            result.append(Recipient(
                // The suffix asks again of people who agreed before Intelli
                // Sense started sending the text around the cursor.
                key: "llm:\(llm.provider):context",
                name: ProviderNames.llm(llm.provider),
                receives: L(
                    "识别出的文字（仅限智能感知、润色、翻译等使用文本模型的模式）；智能感知还会附上输入框里光标前后的一小段文字，可以在「设置」里关掉",
                    "The recognized text (only in modes that use a text model, such as Intelli Sense, Voice Polish and Translate). Intelli Sense also sends a short stretch of the text around the cursor, which you can turn off in Settings"
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
