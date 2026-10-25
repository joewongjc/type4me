#if DEBUG
import Foundation
import Speech

/// Simulator check for the built-in services: `T4M_SELFTEST=<pcm file>` (raw
/// 16 kHz mono 16-bit PCM in the App Group's Library folder) runs it through
/// Apple Speech, then Voice Polish on the on-device model, and writes the
/// results to `Library/selftest.txt` in the App Group.
enum BuiltInSelfTest {
    static func runIfRequested() {
        guard let name = ProcessInfo.processInfo.environment["T4M_SELFTEST"],
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroupID)?
                .appendingPathComponent("Library"),
              let pcm = try? Data(contentsOf: base.appendingPathComponent(name))
        else { return }
        let locale = ProcessInfo.processInfo.environment["T4M_SELFTEST_LOCALE"] ?? AppleSpeechClient.defaultLocaleIdentifier
        Task {
            var lines = ["locale=\(locale) bytes=\(pcm.count)"]
            let authorized = await AppleSpeechClient.requestAuthorization()
            lines.append("authorized=\(authorized) onDeviceModel=\(OnDeviceModel.isAvailable) reason=\(OnDeviceModel.unavailableReason ?? "-")")
            lines.append("onDeviceSpeech=\(SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false) server=\(ProcessInfo.processInfo.environment["T4M_SPEECH_SERVER"] ?? "0")")
            var text = ""
            do {
                let client = AppleSpeechClient()
                guard let config = AppleASRConfig(credentials: ["localeIdentifier": locale]) else { return }
                try await client.connect(config: config, options: ASRRequestOptions())
                let events = await client.events
                let collector = Task { () -> String in
                    var last = ""
                    for await event in events {
                        if case .transcript(let t) = event { last = t.displayText }
                        if case .error(let e) = event { lines.append("asr error: \(e.localizedDescription)") }
                    }
                    return last
                }
                var offset = 0
                while offset < pcm.count {
                    let end = min(offset + 3_200, pcm.count)
                    try await client.sendAudio(pcm.subdata(in: offset..<end))
                    offset = end
                }
                try await client.endAudio()
                text = await collector.value
                lines.append("asr: \(text)")
            } catch {
                lines.append("asr failed: \(error.localizedDescription)")
            }
            if !text.isEmpty, let request = ModePrompts.request(for: .formalWriting, text: text) {
                let started = Date()
                do {
                    let out = try await OnDeviceModel.complete(system: request.system, user: request.user, timeout: 30)
                    lines.append("polish (\(Int(Date().timeIntervalSince(started) * 1000)) ms): \(out)")
                } catch {
                    lines.append("polish failed: \(error.localizedDescription)")
                }
            }
            try? lines.joined(separator: "\n").write(to: base.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
