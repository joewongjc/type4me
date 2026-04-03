import Foundation

enum PrivacyPreferences {
    static let allowSensitivePromptContextKey = "tf_allowSensitivePromptContext"
    static let sonioxAsyncCalibrationKey = "tf_sonioxAsyncCalibration"

    static var allowSensitivePromptContext: Bool {
        UserDefaults.standard.object(forKey: allowSensitivePromptContextKey) as? Bool ?? false
    }

    static var sonioxAsyncCalibrationEnabled: Bool {
        UserDefaults.standard.object(forKey: sonioxAsyncCalibrationKey) as? Bool ?? false
    }

    static func shouldCapturePromptContext(for prompt: String, llmProvider: LLMProvider?) -> Bool {
        guard PromptContext.referencesSensitiveVariables(in: prompt) else { return false }
        if let llmProvider, llmProvider.isLocal {
            return true
        }
        return allowSensitivePromptContext
    }
}
