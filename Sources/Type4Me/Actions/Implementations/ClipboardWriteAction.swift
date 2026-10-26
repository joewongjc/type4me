import AppKit
import Foundation

struct ClipboardWriteAction: MacAction {
    let name = "clipboard_write"
    let description = "Write text to the macOS clipboard so the user can paste it elsewhere."
    let parametersSchema: [String: String] = [
        "text": "The text to put on the clipboard"
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return .failure(L("缺少文本内容", "Missing text"))
        }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        let preview = text.count > 30 ? String(text.prefix(30)) + "…" : text
        return .ok(L("已复制：\(preview)", "Copied: \(preview)"))
    }
}
