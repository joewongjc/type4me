import Foundation

struct LockScreenAction: MacAction {
    let name = "lock_screen"
    let description = "Lock the Mac screen immediately."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        // /usr/bin/pmset displaysleepnow turns the display off, which on most
        // Macs with "Require password immediately" effectively locks the screen.
        // For an explicit lock, we use the System Events Cmd+Ctrl+Q shortcut.
        let script = """
        tell application "System Events" to key code 12 using {control down, command down}
        """
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("屏幕已锁定", "Screen locked"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
