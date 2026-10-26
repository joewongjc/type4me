import AppKit
import Foundation

struct ClipboardSnapshot: Sendable {
    /// Only safe, non-blocking text types are captured.
    /// Binary types (images, RTF, file promises) are skipped because
    /// reading them can trigger lazy data providers in other apps,
    /// blocking the calling thread indefinitely.
    private static let safeTypes: [NSPasteboard.PasteboardType] = [
        .string,
        .URL,
        .html,
        NSPasteboard.PasteboardType("public.utf8-plain-text"),
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("public.url"),
    ]

    struct Item: Sendable {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }
    let items: [Item]
    let changeCount: Int

    static func capture(from pb: NSPasteboard = .general) -> ClipboardSnapshot {
        let changeCount = pb.changeCount
        let safeSet = Set(safeTypes.map(\.rawValue))
        var items: [Item] = []
        for pbItem in pb.pasteboardItems ?? [] {
            let textTypes = pbItem.types.filter { safeSet.contains($0.rawValue) }
            guard !textTypes.isEmpty else { continue }
            var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in textTypes {
                if let data = pbItem.data(forType: type) {
                    dataMap[type] = data
                }
            }
            items.append(Item(types: textTypes, data: dataMap))
        }
        return ClipboardSnapshot(items: items, changeCount: changeCount)
    }

    func restore(
        to pb: NSPasteboard = .general,
        expectedChangeCount: Int
    ) {
        guard pb.changeCount == expectedChangeCount else { return }
        pb.clearContents()

        let restoredItems = items.map { item in
            let pbItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data[type] {
                    pbItem.setData(data, forType: type)
                }
            }
            PasteboardHistoryPolicy.markTransient(pbItem)
            return pbItem
        }
        guard !restoredItems.isEmpty else { return }
        pb.writeObjects(restoredItems)
    }
}
