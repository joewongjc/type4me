import Foundation

struct CloseWindowAction: MacAction {
    let name = "close_window"
    let description = "Close the frontmost window of the active app (Cmd+W)."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        let script = "tell application \"System Events\" to keystroke \"w\" using command down"
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("窗口已关闭", "Window closed"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
