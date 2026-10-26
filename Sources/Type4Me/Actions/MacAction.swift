import Foundation

/// Result returned by a MacAction execution.
struct MacActionResult: Sendable {
    let success: Bool
    let displayMessage: String       // Shown in the floating bar feedback
    let errorMessage: String?

    static func ok(_ message: String) -> MacActionResult {
        MacActionResult(success: true, displayMessage: message, errorMessage: nil)
    }

    static func failure(_ message: String) -> MacActionResult {
        MacActionResult(success: false, displayMessage: "", errorMessage: message)
    }
}

/// Outcome of a Mac Action attempt, used to drive the floating-bar icon/colour.
/// - success: tool_call dispatched and the action returned `success`.
/// - failure: tool_call dispatched but the action failed, or the named action
///   isn't registered. Renders as a red ✗.
/// - unsure: the LLM didn't return a tool_call (e.g. NO_MATCH or freeform reply),
///   meaning we don't know what the user wanted. Renders as a yellow ?.
enum MacActionResultStatus: Sendable, Equatable {
    case success
    case failure
    case unsure
}

/// Local-only context captured before recording starts. Contextual actions can
/// use it without exposing selected text to the LLM tool arguments.
struct MacActionContext: Sendable, Equatable {
    let selectedText: String

    static let empty = MacActionContext(selectedText: "")
}

/// A macOS action exposed to the LLM as a tool. The LLM picks one based on the
/// user's voice intent and supplies arguments; the registry dispatches it.
protocol MacAction: Sendable {
    /// Stable identifier used in `<tool_call>{"name": ...}</tool_call>`.
    var name: String { get }

    /// Short description shown to the LLM in the system prompt.
    var description: String { get }

    /// Map of parameter name → human description, e.g. `["app": "application name"]`.
    var parametersSchema: [String: String] { get }

    /// Execute the action with arguments supplied by the LLM.
    func execute(args: [String: Any]) async -> MacActionResult
}

/// Opt-in protocol for actions that need locally captured context. Existing
/// actions continue using the context-free MacAction interface unchanged.
protocol ContextualMacAction: MacAction {
    func execute(args: [String: Any], context: MacActionContext) async -> MacActionResult
}

extension ContextualMacAction {
    func execute(args: [String: Any]) async -> MacActionResult {
        await execute(args: args, context: .empty)
    }
}
