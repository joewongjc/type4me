import Foundation

enum CrossModeFinishDecision: Equatable {
    case cancel
    case finish(processingMode: ProcessingMode, allowsModeSwitch: Bool)
    case recover
    case ignore
}

enum CrossModeFinishRouter {
    static func decide(
        phase: FloatingBarPhase,
        startingMode: ProcessingMode,
        newMode: ProcessingMode,
        resolvedMode: ProcessingMode?,
        allowsModeSwitch: Bool
    ) -> CrossModeFinishDecision {
        if phase == .recovering {
            return .recover
        }
        if phase == .preparing {
            return .cancel
        }
        guard phase == .recording else {
            return .ignore
        }

        let endingMode: ProcessingMode
        if allowsModeSwitch, let resolvedMode {
            endingMode = resolvedMode
        } else {
            endingMode = newMode
        }
        let processingMode = CrossModeFinishPreference.processingMode(
            startingMode: startingMode,
            endingMode: endingMode,
            isEnabled: allowsModeSwitch
        )
        return .finish(processingMode: processingMode, allowsModeSwitch: allowsModeSwitch)
    }
}
