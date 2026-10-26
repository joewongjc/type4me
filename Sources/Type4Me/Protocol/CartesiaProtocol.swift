import Foundation

enum CartesiaProtocolError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case serverError(title: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L("无法生成 Cartesia WebSocket URL", "Failed to build Cartesia WebSocket URL")
        case let .serverError(title, message):
            return "Cartesia \(title): \(message)"
        }
    }
}

struct CartesiaTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
}

enum CartesiaProtocol {
    static let endpoint = "wss://api.cartesia.ai/stt/websocket"
    static let apiVersion = "2026-08-14"

    static func buildWebSocketURL(config: CartesiaASRConfig, options: ASRRequestOptions) throws -> URL {
        guard var components = URLComponents(string: endpoint) else { throw CartesiaProtocolError.invalidEndpoint }
        var queryItems = [
            URLQueryItem(name: "model", value: CartesiaASRConfig.model),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "cartesia_version", value: apiVersion),
            URLQueryItem(name: "language", value: CartesiaASRConfig.language),
        ]
        queryItems.append(contentsOf: options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100)
            .map { URLQueryItem(name: "keyterm", value: $0) })
        components.queryItems = queryItems
        guard let url = components.url else { throw CartesiaProtocolError.invalidEndpoint }
        return url
    }

    static func makeTranscriptUpdate(from data: Data, confirmedSegments: [String]) throws -> CartesiaTranscriptUpdate? {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.type == "error" {
            throw CartesiaProtocolError.serverError(title: response.title ?? "Error", message: response.message ?? "Unknown server error")
        }
        guard response.type == "transcript" else { return nil }
        let text = response.text ?? ""
        var confirmed = confirmedSegments
        let partial: String
        if response.isFinal == true {
            if !text.isEmpty { confirmed.append(text) }
            partial = ""
        } else {
            partial = text
        }
        let transcript = RecognitionTranscript(
            confirmedSegments: confirmed,
            partialText: partial,
            authoritativeText: (confirmed + (partial.isEmpty ? [] : [partial])).joined(),
            isFinal: response.isFinal ?? false
        )
        return CartesiaTranscriptUpdate(transcript: transcript, confirmedSegments: confirmed)
    }

    private struct Response: Decodable {
        let type: String
        let isFinal: Bool?
        let text: String?
        let title: String?
        let message: String?
        enum CodingKeys: String, CodingKey { case type; case isFinal = "is_final"; case text; case title; case message }
    }
}
