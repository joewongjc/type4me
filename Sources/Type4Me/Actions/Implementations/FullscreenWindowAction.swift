import Foundation

struct FullscreenWindowAction: MacAction {
    let name = "fullscreen_window"
    let description = "Toggle fullscreen for the frontmost window (Ctrl+Cmd+F)."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        let script = """
        tell application "System Events"
            keystroke "f" using {command down, control down}
        end tell
        """
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("已切换全屏", "Toggled fullscreen"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
