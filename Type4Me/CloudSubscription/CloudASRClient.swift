import Foundation
@preconcurrency import AVFoundation
import os

enum CloudASRError: Error, LocalizedError {
    case unsupportedProvider
    case notAuthenticated
    case invalidRegion

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "CloudASRClient requires CloudASRConfig"
        case .notAuthenticated: return "Please log in to Type4Me Cloud"
        case .invalidRegion: return "Could not determine region"
        }
    }
}

/// Cloud ASR client that delegates to the appropriate upstream client
/// (VolcASRClient for China, SonioxASRClient for overseas) but routes
/// traffic through the Type4Me Cloud proxy.
actor CloudASRClient: SpeechRecognizer {

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "CloudASRClient"
    )

    private var inner: (any SpeechRecognizer)?

    var events: AsyncStream<RecognitionEvent> {
        get async {
            guard let inner else {
                return AsyncStream { $0.finish() }
            }
            return await inner.events
        }
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard config is CloudASRConfig else {
            throw CloudASRError.unsupportedProvider
        }

        guard let token = await CloudAuthManager.shared.accessToken() else {
            throw CloudASRError.notAuthenticated
        }

        let region = CloudConfig.currentRegion
        let endpoint = CloudConfig.apiEndpoint + "/asr"

        // Pass JWT + device ID via query params (WebSocket upgrade doesn't support custom headers in URLSession)
        let deviceID = await CloudAPIClient.shared.deviceID
        let authedEndpoint = endpoint + "?token=" + token + "&device_id=" + deviceID

        var proxyOptions = options
        proxyOptions.cloudProxyURL = authedEndpoint

        if region == .cn {
            // China: speak Volcengine protocol through our proxy
            let volcConfig = VolcanoASRConfig(credentials: [
                "appKey": "cloud", "accessKey": "cloud", "resourceId": VolcanoASRConfig.resourceIdSeedASR
            ])!
            let client = VolcASRClient()
            try await client.connect(config: volcConfig, options: proxyOptions)
            inner = client
            logger.info("Connected via Cloud proxy (CN/Volcengine)")
        } else {
            // Overseas: speak Soniox protocol through our proxy
            let sonioxConfig = SonioxASRConfig(credentials: ["apiKey": "cloud"])!
            let client = SonioxASRClient()
            try await client.connect(config: sonioxConfig, options: proxyOptions)
            inner = client
            logger.info("Connected via Cloud proxy (Overseas/Soniox)")
        }
    }

    func sendAudio(_ data: Data) async throws {
        try await inner?.sendAudio(data)
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        try await inner?.sendAudioBuffer(buffer)
    }

    func endAudio() async throws {
        try await inner?.endAudio()
    }

    func disconnect() async {
        await inner?.disconnect()
        inner = nil
    }
}
