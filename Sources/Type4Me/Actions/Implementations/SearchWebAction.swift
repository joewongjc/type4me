import AppKit
import Foundation

struct SearchWebAction: MacAction {
    let name = "search_web"
    let description = "Open the default browser with a Google search for the given query."
    let parametersSchema: [String: String] = [
        "query": "The search query"
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else {
            return .failure(L("缺少搜索内容", "Missing search query"))
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            return .failure(L("无效的查询", "Invalid query"))
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if opened {
            return .ok(L("正在搜索：\(query)", "Searching: \(query)"))
        } else {
            return .failure(L("无法打开浏览器", "Failed to open browser"))
        }
    }
}
