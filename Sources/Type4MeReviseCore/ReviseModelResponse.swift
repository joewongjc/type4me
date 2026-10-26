import Foundation

public struct ReviseModelResponse: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let intent: ReviseIntent
    public let scope: ReviseScopeDescriptor
    public let ambiguous: Bool
    public let externalActionRequested: Bool
    public let result: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        intent: ReviseIntent,
        scope: ReviseScopeDescriptor,
        ambiguous: Bool,
        externalActionRequested: Bool,
        result: String
    ) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.scope = scope
        self.ambiguous = ambiguous
        self.externalActionRequested = externalActionRequested
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case intent
        case scope
        case ambiguous
        case externalActionRequested = "external_action_requested"
        case result
    }
}

public enum ReviseModelResponseParser {
    public static func strippingThinkTags(_ text: String) -> String {
        var result = text
        let pattern = #"(?s)<think>.*?</think>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    public static func parse(rawText: String) -> Result<ReviseModelResponse, ReviseRejection> {
        let stripped = strippingThinkTags(rawText)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8) else {
            return .failure(.malformedJSON)
        }

        guard data.count <= ReviseInputBudget.maxModelResponseBytes else {
            return .failure(.responseTooLarge)
        }

        guard !trimmed.isEmpty else {
            return .failure(.emptyOutput)
        }

        // Strict: Reject markdown code blocks or explanations outside JSON
        if trimmed.contains("```") {
            return .failure(.codeFence)
        }

        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else {
            return .failure(.malformedJSON)
        }

        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(ReviseModelResponse.self, from: data)
            guard response.schemaVersion == ReviseModelResponse.currentSchemaVersion else {
                return .failure(.schemaVersionMismatch)
            }
            return .success(response)
        } catch {
            return .failure(.malformedJSON)
        }
    }
}
