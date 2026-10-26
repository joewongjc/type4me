import Foundation

struct GetBatteryAction: MacAction {
    let name = "get_battery"
    let description = "Get the current battery percentage and charging status."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        do {
            let output = try await AppleScriptRunner.runShell("/usr/bin/pmset -g batt")
            // Sample output:
            // "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=...)  87%; discharging; ..."
            if let percentRange = output.range(of: #"\d+%"#, options: .regularExpression) {
                let percent = output[percentRange]
                let charging = output.lowercased().contains("charging")
                let status = charging
                    ? L("（充电中）", " (charging)")
                    : ""
                return .ok(L("电量：\(percent)\(status)", "Battery: \(percent)\(status)"))
            }
            return .ok(output)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
