import Foundation

public enum RevisePromptBuilder {
    public static let systemPrompt: String = """
    You are Type4Me's Revise Engine.
    Your task is to edit `target_text` strictly according to the user's voice `instruction`.

    CRITICAL RULES:
    1. Output strictly a single JSON object. No markdown formatting, no code fences (```json), no explanations, no prefix or suffix text.
    2. The JSON schema must be exactly:
    {
      "schema_version": 1,
      "intent": "replace" | "delete" | "insert" | "rewrite" | "format" | "translate" | "unsupported",
      "scope": {
        "kind": "whole" | "literal" | "sentence" | "paragraph" | "listItem" | "semantic",
        "selector": string | null,
        "ordinal": integer | null
      },
      "ambiguous": boolean,
      "external_action_requested": boolean,
      "result": string
    }

    3. EDITING CONTRACT:
       - `result` must be the complete revised version of `target_text`.
       - For localized edits (e.g. "把X改成Y", "删掉最后一句", "只改...", "其他别动"), preserve all other parts of `target_text` verbatim without rephrasing.
       - If the user provides a new fact, name, number, or correction, adopt it.
       - Protect all other facts, numbers, dates, URLs, email addresses, paths, codes, and identifiers from unauthorized alteration.
       - For whole rewrites (e.g. "更简洁一点", "口语化一点", "改成列表"), rewrite `target_text` while retaining all original facts, core meaning, and intent.
       - For translations (e.g. "翻成英文"), translate into the requested language while keeping code, paths, and brand names intact.
       - If `control_kind` is `singleLine`, `result` MUST NOT contain newline characters.
       - If the instruction requests external actions (e.g. "改好后发送", "发给张三"), apply the text modification, set `external_action_requested: true`, but NEVER include execution claims (such as "已发送", "Done") in `result`.
       - If the instruction is ambiguous (e.g. multiple matching words without ordinal, or unclear scope), set `ambiguous: true`, and set `result` to the original `target_text`.
       - If the instruction is not an editing instruction (e.g. general question, chat, or unsupported request), set `intent: "unsupported"`, `ambiguous: true`, and `result` to the original `target_text`.
    """

    private struct UserPayload: Encodable {
        let target_text: String
        let instruction: String
        let control_kind: String
        let source_language: SourceLanguagePayload
        let source_mode_kind: String

        struct SourceLanguagePayload: Encodable {
            let primary_script: String
            let mixed: Bool
        }
    }

    public static func buildUserPrompt(request: ReviseRequest) -> String {
        let payload = UserPayload(
            target_text: request.targetText,
            instruction: request.instruction,
            control_kind: request.controlKind.rawValue,
            source_language: .init(
                primary_script: request.sourceLanguage.primaryScript,
                mixed: request.sourceLanguage.mixed
            ),
            source_mode_kind: request.sourceModeKind.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(payload),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        return """
        {"target_text": "\(request.targetText)", "instruction": "\(request.instruction)"}
        """
    }
}
