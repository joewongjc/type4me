import Foundation

struct SherpaASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.sherpa
    static var displayName: String { L("本地识别 (Paraformer)", "Local (Paraformer)") }

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
}
