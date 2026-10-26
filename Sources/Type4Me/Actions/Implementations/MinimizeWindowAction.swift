import Foundation

struct MinimizeWindowAction: MacAction {
    let name = "minimize_window"
    let description = "Minimize the frontmost window of the active app."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        let script = "tell application \"System Events\" to keystroke \"m\" using command down"
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("窗口已最小化", "Window minimized"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
