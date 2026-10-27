import Foundation
import Type4MeCorrectionCore
import Type4MeIntelliSenseCore

/// Turns "the selection is wrong, and here is what I said" into the text to
/// write, with the text model when there is one.
@MainActor
enum CorrectionRunner {
    enum Result {
        case replace(CorrectionOutcome)
        case failed(String)
    }

    static func run(spoken: String, request: CorrectionRequest, log: DiagnosticsLog) async -> Result {
        var request = request
        // The same rule Intelli Sense follows: context that looks like a
        // credential stays on the phone.
        if !request.before.isEmpty || !request.after.isEmpty,
           IntelliSenseSensitiveTextScanner.containsSensitiveContent(request.before + request.selected + request.after) {
            request.before = ""
            request.after = ""
        }

        guard let endpoint = ConfigStore.llm, let config = LLMEndpointConfig(endpoint: endpoint) else {
            // Without a model, saying it again is the whole correction.
            guard spoken != request.selected else { return .failed(unclear) }
            log.add(L("纠正完成：没有处理模型，用了识别原文", "Correction done: no text model, so the recognized words were used"))
            return .replace(CorrectionOutcome(replacement: spoken))
        }

        let input = CorrectionPrompt.Input(
            before: request.before, selected: request.selected, after: request.after,
            spoken: spoken, attempts: request.attempts
        )
        let prompt = CorrectionPrompt.build(input, chinese: AppLanguage.current == .zh)
        let occurrences = CorrectionOccurrences.find(before: request.before, after: request.after, matching: request.selected)
        let started = Date()
        do {
            let raw = try await ChatClient(config: config).complete(system: prompt.system, user: prompt.user)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch CorrectionResponse.resolve(raw, selected: request.selected, attempts: request.attempts, occurrenceCount: occurrences.count) {
            case .replace(let text, let also):
                log.add(L(
                    "纠正完成，用时 \(ms) ms，另有 \(also.count) 处一起改",
                    "Correction done in \(ms) ms, \(also.count) more places to change"
                ))
                return .replace(CorrectionOutcome(replacement: text, also: also))
            case .unclear:
                log.add(L("纠正没有结果，用时 \(ms) ms", "Correction gave no answer in \(ms) ms"))
                return .failed(unclear)
            }
        } catch {
            log.add(L("纠正失败：\(error.localizedDescription)", "Correction failed: \(error.localizedDescription)"))
            return .failed(L("纠正失败：\(error.localizedDescription)", "Correction failed: \(error.localizedDescription)"))
        }
    }

    private static var unclear: String {
        L("没听清要改成什么，再说一次", "Couldn't tell what it should be. Try again")
    }
}
