import Foundation

struct ToggleDarkModeAction: MacAction {
    let name = "toggle_dark_mode"
    let description = "Toggle macOS appearance between light mode and dark mode."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
                return dark mode
            end tell
        end tell
        """
        do {
            let output = try await AppleScriptRunner.runScript(script)
            let isDark = output.lowercased() == "true"
            return .ok(
                isDark
                    ? L("已切换到深色模式", "Switched to dark mode")
                    : L("已切换到浅色模式", "Switched to light mode")
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
