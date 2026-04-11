import Foundation
import os

enum CloudLLMError: Error, LocalizedError {
    case notAuthenticated
    case quotaExhausted
    case networkError
    case serverError(Int)
    case remoteError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please log in to Type4Me Cloud"
        case .quotaExhausted: return "Free quota exhausted"
        case .networkError: return "Network error"
        case .serverError(let code): return "Server error (\(code))"
        case .remoteError(let msg): return msg
        case .emptyResponse: return "Empty response from server"
        }
    }
}

/// LLM client that proxies requests through the Type4Me Cloud backend.
/// The backend handles API keys and upstream provider selection.
actor CloudLLMClient: LLMClient {

    private let logger = Logger(subsystem: "com.type4me.app", category: "CloudLLM")

    func warmUp(baseURL: String) async {
        // No warmup needed — proxy handles connection pooling
    }

    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        guard let token = await CloudAuthManager.shared.accessToken() else {
            throw CloudLLMError.notAuthenticated
        }

        let endpoint = CloudConfig.apiEndpoint + "/api/llm"

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        struct LLMRequest: Encodable {
            let text: String
            let prompt: String
            let mode: String
        }

        request.httpBody = try JSONEncoder().encode(
            LLMRequest(text: text, prompt: prompt, mode: "cloud")
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CloudLLMError.networkError
        }

        if http.statusCode == 401 {
            throw CloudLLMError.notAuthenticated
        }
        if http.statusCode == 429 {
            throw CloudLLMError.quotaExhausted
        }
        guard http.statusCode == 200 else {
            logger.error("Cloud LLM error: status \(http.statusCode)")
            throw CloudLLMError.serverError(http.statusCode)
        }

        struct LLMResponse: Decodable {
            let result: String?
            let error: String?
        }

        let resp = try JSONDecoder().decode(LLMResponse.self, from: data)
        if let error = resp.error {
            throw CloudLLMError.remoteError(error)
        }
        guard let result = resp.result else {
            throw CloudLLMError.emptyResponse
        }
        return result
    }
}
