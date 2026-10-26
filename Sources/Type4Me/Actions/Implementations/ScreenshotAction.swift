import Foundation

struct ScreenshotAction: MacAction {
    let name = "screenshot"
    let description = "Take a screenshot. Default is interactive selection saved to Desktop."
    let parametersSchema: [String: String] = [
        "mode": "Optional: \"selection\" (default, lets user drag), \"window\", or \"fullscreen\""
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        let mode = (args["mode"] as? String)?.lowercased() ?? "selection"
        let flag: String
        switch mode {
        case "window": flag = "-w"
        case "fullscreen", "full": flag = ""
        default: flag = "-i"          // interactive (drag-to-select)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let path = "$HOME/Desktop/Screenshot-\(timestamp).png"
        let command = flag.isEmpty
            ? "/usr/sbin/screencapture \(path)"
            : "/usr/sbin/screencapture \(flag) \(path)"

        do {
            // Interactive screenshots can wait indefinitely for user selection.
            _ = try await AppleScriptRunner.runShell(command, timeoutSeconds: 60)
            return .ok(L("截图已保存到桌面", "Screenshot saved to Desktop"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
