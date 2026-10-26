import AppKit

/// Marks Type4Me's internal pasteboard traffic so clipboard-history apps do not
/// treat temporary injection and restoration as user-initiated copies.
enum PasteboardHistoryPolicy {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func markTransient(_ item: NSPasteboardItem) {
        item.setData(Data(), forType: transientType)
    }

    static func shouldRestoreTemporaryCopy(
        previousChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        currentChangeCount != previousChangeCount
    }
}
