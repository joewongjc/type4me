import AppKit

/// Marks Type4Me's internal pasteboard traffic so clipboard-history apps do not
/// treat temporary injection and restoration as user-initiated copies.
enum PasteboardHistoryPolicy {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @discardableResult
    static func markTransient(_ item: NSPasteboardItem) -> Bool {
        item.setData(Data(), forType: transientType)
    }

    static func publishText(
        _ text: String, transient: Bool, write: (NSPasteboardItem) -> Bool
    ) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              !transient || markTransient(item)
        else { return false }
        return write(item)
    }

    static func shouldRestoreTemporaryCopy(
        previousChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        currentChangeCount != previousChangeCount
    }
}
