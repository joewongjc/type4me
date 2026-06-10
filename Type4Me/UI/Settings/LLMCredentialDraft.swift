import Foundation

enum LLMCredentialDraft {
    static func effectiveValues(
        fields: [CredentialField],
        savedValues: [String: String],
        draftValues: [String: String],
        editedFields: Set<String>
    ) -> [String: String] {
        var result: [String: String] = Dictionary(
            uniqueKeysWithValues: fields.compactMap { field in
                guard !field.defaultValue.isEmpty else { return nil }
                return (field.key, field.defaultValue)
            }
        )
        result.merge(savedValues) { _, saved in saved }
        for key in editedFields {
            result[key] = draftValues[key] ?? ""
        }
        return result
    }

    static func hasRequiredValues(
        fields: [CredentialField],
        values: [String: String]
    ) -> Bool {
        fields
            .filter { !$0.isOptional }
            .allSatisfy { field in
                !(values[field.key] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
    }
}
