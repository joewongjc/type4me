import Testing
@testable import Type4Me

struct LLMCredentialDraftTests {
    private let fields = [
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: "Model",
            placeholder: "model",
            isSecure: false,
            isOptional: false,
            defaultValue: "default-model"
        ),
        CredentialField(
            key: "baseURL",
            label: "Base URL",
            placeholder: "https://example.com/v1",
            isSecure: false,
            isOptional: true,
            defaultValue: "https://example.com/v1"
        ),
    ]

    @Test
    func defaultModelMakesNewAPIKeyDraftComplete() {
        let values = LLMCredentialDraft.effectiveValues(
            fields: fields,
            savedValues: [:],
            draftValues: ["apiKey": "secret"],
            editedFields: ["apiKey"]
        )

        #expect(values["apiKey"] == "secret")
        #expect(values["model"] == "default-model")
        #expect(values["baseURL"] == "https://example.com/v1")
        #expect(LLMCredentialDraft.hasRequiredValues(fields: fields, values: values))
    }

    @Test
    func savedValuesOverrideDefaults() {
        let values = LLMCredentialDraft.effectiveValues(
            fields: fields,
            savedValues: [
                "apiKey": "saved-secret",
                "model": "saved-model",
                "baseURL": "https://saved.example/v1",
            ],
            draftValues: [:],
            editedFields: []
        )

        #expect(values["apiKey"] == "saved-secret")
        #expect(values["model"] == "saved-model")
        #expect(values["baseURL"] == "https://saved.example/v1")
    }

    @Test
    func explicitEditOverridesSavedValue() {
        let values = LLMCredentialDraft.effectiveValues(
            fields: fields,
            savedValues: ["apiKey": "old-secret", "model": "saved-model"],
            draftValues: ["apiKey": "new-secret"],
            editedFields: ["apiKey"]
        )

        #expect(values["apiKey"] == "new-secret")
        #expect(values["model"] == "saved-model")
    }

    @Test
    func explicitClearDoesNotRestoreSavedValue() {
        let values = LLMCredentialDraft.effectiveValues(
            fields: fields,
            savedValues: ["apiKey": "saved-secret", "model": "saved-model"],
            draftValues: ["apiKey": ""],
            editedFields: ["apiKey"]
        )

        #expect(values["apiKey"] == "")
        #expect(!LLMCredentialDraft.hasRequiredValues(fields: fields, values: values))
    }

    @Test
    func whitespaceOnlyRequiredValueIsIncomplete() {
        let values = ["apiKey": " \n ", "model": "default-model"]

        #expect(!LLMCredentialDraft.hasRequiredValues(fields: fields, values: values))
    }
}
