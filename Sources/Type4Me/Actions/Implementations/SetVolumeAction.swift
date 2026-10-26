import Foundation

struct SetVolumeAction: MacAction {
    let name = "set_volume"
    let description = "Set the system output volume to a specific level (0-100)."
    let parametersSchema: [String: String] = [
        "level": "Volume level as an integer between 0 and 100"
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        let raw = args["level"]
        let level: Int
        if let n = raw as? Int { level = n }
        else if let d = raw as? Double { level = Int(d) }
        else if let s = raw as? String, let n = Int(s) { level = n }
        else {
            return .failure(L("缺少音量值", "Missing volume level"))
        }

        let clamped = max(0, min(100, level))
        do {
            _ = try await AppleScriptRunner.runScript("set volume output volume \(clamped)")
            return .ok(L("音量已设为 \(clamped)", "Volume set to \(clamped)"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
