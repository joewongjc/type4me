import Foundation
import os

/// Soniox async (file-based) transcription client.
/// Uploads complete audio → creates transcription → polls until done → returns text.
enum SonioxAsyncClient {

    private static let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "SonioxAsyncClient"
    )

    private static let baseURL = "https://api.soniox.com"

    struct TranscriptionResult: Sendable {
        let text: String
    }

    /// Transcribe a complete audio buffer using the Soniox async API.
    /// - Parameters:
    ///   - audioData: Raw PCM s16le 16kHz mono audio
    ///   - apiKey: Soniox API key
    ///   - hotwords: Optional hotword list for context.terms
    ///   - bypassProxy: Whether to bypass system proxy
    /// - Returns: Transcribed text, or nil if failed
    static func transcribe(
        audioData: Data,
        apiKey: String,
        hotwords: [String] = [],
        bypassProxy: Bool = false
    ) async -> TranscriptionResult? {
        let startTime = ContinuousClock.now

        guard !audioData.isEmpty else {
            logger.warning("Empty audio data, skipping async transcription")
            return nil
        }

        let sessionConfig = URLSessionConfiguration.default
        if bypassProxy {
            sessionConfig.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: sessionConfig)

        var fileId: String?
        var transcriptionId: String?

        do {
            // Step 1: Upload audio file
            fileId = try await uploadAudio(audioData, apiKey: apiKey, session: session)
            NSLog("[SonioxAsync] Uploaded file: %@", fileId!)

            // Step 2: Create transcription
            transcriptionId = try await createTranscription(
                fileId: fileId!,
                apiKey: apiKey,
                hotwords: hotwords,
                session: session
            )
            NSLog("[SonioxAsync] Created transcription: %@", transcriptionId!)

            // Step 3: Poll until completed
            try await waitUntilCompleted(transcriptionId!, apiKey: apiKey, session: session)

            // Step 4: Get transcript
            let text = try await getTranscript(transcriptionId!, apiKey: apiKey, session: session)

            let elapsed = ContinuousClock.now - startTime
            NSLog("[SonioxAsync] Transcription completed in %@: %d chars", String(describing: elapsed), text.count)
            DebugFileLogger.log("SonioxAsync completed in \(elapsed): \(text.count) chars")

            // Return result immediately, clean up in background
            let fid = fileId
            let tid = transcriptionId
            let key = apiKey
            Task.detached {
                await cleanUp(fileId: fid, transcriptionId: tid, apiKey: key, session: session)
                session.invalidateAndCancel()
            }

            return TranscriptionResult(text: text)
        } catch {
            let elapsed = ContinuousClock.now - startTime
            NSLog("[SonioxAsync] Failed after %@: %@", String(describing: elapsed), String(describing: error))
            DebugFileLogger.log("SonioxAsync failed after \(elapsed): \(error)")

            let fid = fileId
            let tid = transcriptionId
            let key = apiKey
            Task.detached {
                await cleanUp(fileId: fid, transcriptionId: tid, apiKey: key, session: session)
                session.invalidateAndCancel()
            }

            return nil
        }
    }

    // MARK: - API calls

    private static func uploadAudio(
        _ audioData: Data,
        apiKey: String,
        session: URLSession
    ) async throws -> String {
        let wavData = WAVEncoder.encode(pcmData: audioData)

        let url = URL(string: "\(baseURL)/v1/files")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let fileId = json?["id"] as? String else {
            throw SonioxAsyncError.invalidResponse(L("缺少文件 ID", "Missing file id"))
        }
        return fileId
    }

    private static func createTranscription(
        fileId: String,
        apiKey: String,
        hotwords: [String],
        session: URLSession
    ) async throws -> String {
        let url = URL(string: "\(baseURL)/v1/transcriptions")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var config: [String: Any] = [
            "model": SonioxASRConfig.asyncModel,
            "file_id": fileId,
            "language_hints": ["zh", "en"],
            "language_hints_strict": true,
        ]

        var context: [String: Any] = [:]
        context["general"] = [
            ["key": "domain", "value": "voice input"],
            ["key": "topic", "value": "general dictation and tech discussion"],
        ]
        let terms = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty {
            context["terms"] = terms
        }
        config["context"] = context

        request.httpBody = try JSONSerialization.data(withJSONObject: config)

        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let transcriptionId = json?["id"] as? String else {
            throw SonioxAsyncError.invalidResponse(L("缺少转写 ID", "Missing transcription id"))
        }
        return transcriptionId
    }

    private static func waitUntilCompleted(
        _ transcriptionId: String,
        apiKey: String,
        session: URLSession,
        maxWait: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now + maxWait

        while ContinuousClock.now < deadline {
            let url = URL(string: "\(baseURL)/v1/transcriptions/\(transcriptionId)")!
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            try checkHTTPResponse(response, data: data)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = json?["status"] as? String

            if status == "completed" {
                return
            } else if status == "error" {
                let message = json?["error_message"] as? String ?? "Unknown error"
                throw SonioxAsyncError.transcriptionFailed(message)
            }

            try await Task.sleep(for: .milliseconds(200))
        }

        throw SonioxAsyncError.timeout
    }

    private static func getTranscript(
        _ transcriptionId: String,
        apiKey: String,
        session: URLSession
    ) async throws -> String {
        let url = URL(string: "\(baseURL)/v1/transcriptions/\(transcriptionId)/transcript")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokens = json?["tokens"] as? [[String: Any]] else {
            throw SonioxAsyncError.invalidResponse(L("缺少识别 token", "Missing tokens"))
        }

        let text = tokens
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    private static func deleteTranscription(
        _ transcriptionId: String,
        apiKey: String,
        session: URLSession
    ) async throws {
        let url = URL(string: "\(baseURL)/v1/transcriptions/\(transcriptionId)")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private static func deleteFile(
        _ fileId: String,
        apiKey: String,
        session: URLSession
    ) async throws {
        let url = URL(string: "\(baseURL)/v1/files/\(fileId)")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    // MARK: - Cleanup

    private static func cleanUp(
        fileId: String?,
        transcriptionId: String?,
        apiKey: String,
        session: URLSession
    ) async {
        if let tid = transcriptionId {
            try? await deleteTranscription(tid, apiKey: apiKey, session: session)
        }
        if let fid = fileId {
            try? await deleteFile(fid, apiKey: apiKey, session: session)
        }
    }

    // MARK: - Helpers

    private static func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SonioxAsyncError.httpError(status: http.statusCode, body: String(body.prefix(200)))
        }
    }
}

enum SonioxAsyncError: Error, LocalizedError {
    case invalidResponse(String)
    case transcriptionFailed(String)
    case httpError(status: Int, body: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): return L("Soniox 异步识别返回无效：\(msg)", "Soniox async: \(msg)")
        case .transcriptionFailed(let msg): return L("Soniox 异步识别失败：\(msg)", "Soniox async failed: \(msg)")
        case .httpError(let status, let body): return L("Soniox 异步识别 HTTP \(status)：\(body)", "Soniox async HTTP \(status): \(body)")
        case .timeout: return L("Soniox 异步识别超时", "Soniox async transcription timed out")
        }
    }
}
