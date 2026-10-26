import Foundation

/// User-defined HTTP batch endpoint: the whole recording is uploaded after the hotkey is released.
/// Request shape (headers, JSON or multipart body, result field) is described by the user so
/// gateways and self-hosted services can be used without a dedicated provider.
struct CustomASRConfig: ASRProviderConfig, Sendable {

    enum UploadFormat: String, Sendable {
        /// JSON body; the WAV recording is inserted as base64 at `{{audio_base64}}`.
        case json
        /// multipart/form-data; each template key is a form field, `{{audio_file}}` marks the WAV file part.
        case multipart
    }

    static let provider = ASRProvider.custom
    static var displayName: String { L("自定义", "Custom") }

    static let defaultResultPath = "text"

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "endpointURL", label: L("请求地址", "Endpoint URL"),
            placeholder: "https://example.com/v1/audio/transcriptions",
            isSecure: false, isOptional: false, defaultValue: "",
            hint: L("松开快捷键后整段录音上传到这里（非实时识别）",
                    "The full recording is uploaded here after you release the hotkey (batch recognition)")
        ),
        CredentialField(
            key: "apiKey", label: L("API Key", "API Key"),
            placeholder: L("可选，保存在钥匙串", "Optional, stored in Keychain"),
            isSecure: true, isOptional: true, defaultValue: ""
        ),
        CredentialField(
            key: "headers", label: L("请求头", "Headers"),
            placeholder: "Authorization: Bearer {{api_key}}",
            isSecure: false, isOptional: true, defaultValue: "",
            isMultiline: true,
            hint: L("每行一个「名称: 值」，用 {{api_key}} 引用 API Key；留空时发送 Authorization: Bearer {{api_key}}",
                    "One \"Name: value\" per line; {{api_key}} inserts the API key. Empty sends Authorization: Bearer {{api_key}}")
        ),
        CredentialField(
            key: "uploadFormat", label: L("上传方式", "Upload Format"),
            placeholder: "", isSecure: false, isOptional: false,
            defaultValue: UploadFormat.json.rawValue,
            options: [
                FieldOption(value: UploadFormat.json.rawValue, label: L("JSON（录音转 base64）", "JSON (base64 audio)")),
                FieldOption(value: UploadFormat.multipart.rawValue, label: L("表单上传（multipart）", "Form upload (multipart)")),
            ]
        ),
        CredentialField(
            key: "bodyTemplate", label: L("请求体模板", "Body Template"),
            placeholder: #"{"model": "your-model", "audio": "{{audio_base64}}"}"#,
            isSecure: false, isOptional: false, defaultValue: "",
            isMultiline: true,
            hint: L("JSON 对象。录音位置写 {{audio_base64}}；表单上传时每个键是一个表单字段，录音字段的值写 {{audio_file}}",
                    "A JSON object. Put {{audio_base64}} where the audio goes; for form upload each key is a form field and the audio field's value is {{audio_file}}")
        ),
        CredentialField(
            key: "resultPath", label: L("结果字段", "Result Field"),
            placeholder: defaultResultPath,
            isSecure: false, isOptional: true, defaultValue: defaultResultPath,
            hint: L("识别文字在响应 JSON 里的位置，如 text 或 results[0].transcript",
                    "Where the transcript sits in the response JSON, e.g. text or results[0].transcript")
        ),
    ]}

    let endpointURL: String
    let apiKey: String
    let headers: String
    let uploadFormat: UploadFormat
    let bodyTemplate: String
    let resultPath: String

    init?(credentials: [String: String]) {
        let endpoint = credentials["endpointURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let template = credentials["bodyTemplate"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !endpoint.isEmpty, !template.isEmpty else { return nil }
        self.endpointURL = endpoint
        self.bodyTemplate = template
        self.apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.headers = credentials["headers"] ?? ""
        self.uploadFormat = UploadFormat(rawValue: credentials["uploadFormat"] ?? "") ?? .json
        let path = credentials["resultPath"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.resultPath = path.isEmpty ? Self.defaultResultPath : path
    }

    func toCredentials() -> [String: String] {
        var result = [
            "endpointURL": endpointURL,
            "uploadFormat": uploadFormat.rawValue,
            "bodyTemplate": bodyTemplate,
            "resultPath": resultPath,
        ]
        if !apiKey.isEmpty { result["apiKey"] = apiKey }
        if !headers.isEmpty { result["headers"] = headers }
        return result
    }

    var isValid: Bool { !endpointURL.isEmpty && !bodyTemplate.isEmpty }
}
