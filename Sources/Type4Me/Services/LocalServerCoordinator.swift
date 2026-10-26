import Foundation
import os

/// Coordinates the local Python server that hosts both ASR and LLM.
/// Both ASRSettingsCard and LLMSettingsCard read state from this coordinator.
@Observable @MainActor
class LocalServerCoordinator {
    var isRunning = false
    var isStarting = false

    private let logger = Logger(subsystem: "com.type4me.server", category: "Coordinator")

    /// Ensure server is running. No-op if already started.
    func ensureRunning() async {
        guard !isRunning && !isStarting else { return }
        isStarting = true
        do {
            try await SenseVoiceServerManager.shared.start()
            isRunning = true
        } catch {
            logger.error("Server start failed: \(error)")
        }
        isStarting = false
    }

    /// Start server + send dummy LLM request to trigger model preloading.
    func preloadLLM() async {
        await ensureRunning()
        let port = SenseVoiceServerManager.currentQwen3Port
        guard let port else { return }
        // Trigger lazy LLM model load
        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = #"{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}"#.data(using: .utf8)
        logger.info("Preloading local LLM model...")
        _ = try? await URLSession.shared.data(for: request)
        logger.info("Local LLM model preloaded")
    }

    /// Stop server only if ASR doesn't need it.
    func stopIfUnneeded() async {
        let asrNeedsLocal = KeychainService.selectedASRProvider == .sherpa
        if !asrNeedsLocal {
            await SenseVoiceServerManager.shared.stop()
            isRunning = false
            logger.info("Server stopped (no longer needed)")
        }
    }

    /// Sync state from SenseVoiceServerManager.
    func refreshStatus() async {
        isRunning = await SenseVoiceServerManager.shared.isRunning
    }
}
