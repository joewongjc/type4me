import Foundation

struct SetBrightnessAction: MacAction {
    let name = "set_brightness"
    let description = "Set the display brightness to a specific level (0-100)."
    let parametersSchema: [String: String] = [
        "level": "Brightness level as an integer between 0 and 100"
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        let raw = args["level"]
        let level: Int
        if let n = raw as? Int { level = n }
        else if let d = raw as? Double { level = Int(d) }
        else if let s = raw as? String, let n = Int(s) { level = n }
        else {
            return .failure(L("缺少亮度值", "Missing brightness level"))
        }

        let clamped = max(0, min(100, level))
        // Try the Homebrew `brightness` CLI first; fall back to AppleScript via System Events.
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brightness") {
            do {
                let normalized = String(format: "%.2f", Double(clamped) / 100.0)
                _ = try await AppleScriptRunner.runShell("/opt/homebrew/bin/brightness \(normalized)")
                return .ok(L("亮度已设为 \(clamped)", "Brightness set to \(clamped)"))
            } catch {
                // Fall through to AppleScript fallback.
            }
        }

        // AppleScript fallback: simulate brightness keys via System Events. Not
        // an exact percentage but works on most Macs without extra tooling.
        let upScript = """
        tell application "System Events"
            repeat \(clamped / 10) times
                key code 144
            end repeat
        end tell
        """
        let downScript = """
        tell application "System Events"
            repeat \((100 - clamped) / 10) times
                key code 145
            end repeat
        end tell
        """
        let script = clamped >= 50 ? upScript : downScript
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("亮度已调整", "Brightness adjusted"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
