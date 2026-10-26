import Foundation

struct ScrollDownAction: MacAction {
    let name = "scroll_down"
    let description = "Scroll down in the frontmost window (Page Down). Works in browsers, documents, terminals."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        // key code 121 = Page Down
        let script = "tell application \"System Events\" to key code 121"
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("已向下滚动", "Scrolled down"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

struct ScrollUpAction: MacAction {
    let name = "scroll_up"
    let description = "Scroll up in the frontmost window (Page Up). Works in browsers, documents, terminals."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any]) async -> MacActionResult {
        // key code 116 = Page Up
        let script = "tell application \"System Events\" to key code 116"
        do {
            _ = try await AppleScriptRunner.runScript(script)
            return .ok(L("已向上滚动", "Scrolled up"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
