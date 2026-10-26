import Foundation

struct SherpaASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.sherpa
    static var displayName: String { L("本地识别 (SenseVoice)", "Local (SenseVoice)") }

    static var credentialFields: [CredentialField] { [] }

    let modelDir: String

    init?(credentials: [String: String]) {
        let dir = credentials["modelDir"] ?? ModelManager.defaultModelsDir
        guard !dir.isEmpty else { return nil }
        self.modelDir = (dir as NSString).expandingTildeInPath
    }

    func toCredentials() -> [String: String] {
        ["modelDir": modelDir]
    }

    var isValid: Bool {
        FileManager.default.fileExists(atPath: modelDir)
    }

    // MARK: - Model sub-paths (derived from selected streaming model)

    /// Path to the selected streaming model directory.
    var onlineModelDir: String {
        (modelDir as NSString).appendingPathComponent(
            ModelManager.selectedStreamingModel.directoryName
        )
    }

    /// Path to the offline Paraformer model directory.
    var offlineModelDir: String {
        (modelDir as NSString).appendingPathComponent(
            ModelManager.AuxModelType.offlineParaformer.directoryName
        )
    }

    /// Path to the CT-Transformer punctuation model directory.
    var punctModelDir: String {
        (modelDir as NSString).appendingPathComponent(
            ModelManager.AuxModelType.punctuation.directoryName
        )
    }

    /// Path to the SenseVoice model directory.
    var senseVoiceModelDir: String {
        (modelDir as NSString).appendingPathComponent(
            ModelManager.StreamingModel.senseVoiceSmall.directoryName
        )
    }

    /// Path to the Silero VAD model directory.
    var vadModelDir: String {
        (modelDir as NSString).appendingPathComponent(
            ModelManager.AuxModelType.sileroVad.directoryName
        )
    }

}
