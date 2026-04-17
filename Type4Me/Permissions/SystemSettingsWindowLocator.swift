import AppKit
import CoreGraphics

/// Locates the System Settings / System Preferences main window on screen so
/// the drag-to-authorize overlay can pin itself to the bottom edge of that
/// window and follow it if the user moves or resizes it.
///
/// Uses only the public `CGWindowListCopyWindowInfo` API (window bounds only,
/// no Screen Recording required) and `NSRunningApplication` for bundle-ID
/// lookup. Matching by bundle ID rather than process name is critical —
/// macOS returns the *localized* owner name here (e.g. "系统设置" in zh-CN),
/// so a hardcoded English name list matches nothing in non-English locales.
enum SystemSettingsWindowLocator {

    /// Bundle identifier for System Settings / System Preferences. This hasn't
    /// changed across the macOS 12 → 13 rename.
    private static let systemSettingsBundleID = "com.apple.systempreferences"

    /// Find the primary window of System Settings, returning its bounds in
    /// the AppKit coordinate space (origin at the bottom-left of the main
    /// display, matching `NSWindow.frame`).
    static func findMainWindowFrame() -> NSRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }

        // Candidate windows: correct owner (by bundle ID), on-screen layer 0
        // (normal window), with reasonable size so we don't pick a popover.
        let candidates: [NSRect] = rawList.compactMap { entry in
            guard
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let app = NSRunningApplication(processIdentifier: pid),
                app.bundleIdentifier == systemSettingsBundleID,
                let layer = entry[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let cgRect = rectFromBoundsDict(boundsDict),
                cgRect.width >= 400,
                cgRect.height >= 300
            else {
                return nil
            }
            return convertCGWindowRectToAppKit(cgRect)
        }

        // Pick the largest — the main settings window dwarfs any detail popovers.
        return candidates.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// `kCGWindowBounds` returns a `CFDictionary` with `X/Y/Width/Height`.
    private static func rectFromBoundsDict(_ dict: [String: CGFloat]) -> CGRect? {
        guard
            let x = dict["X"],
            let y = dict["Y"],
            let width = dict["Width"],
            let height = dict["Height"]
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Core Graphics window coordinates place (0,0) at the top-left of the
    /// primary display, with Y increasing downward. AppKit's `NSWindow.frame`
    /// places (0,0) at the bottom-left of the primary display, with Y
    /// increasing upward. Flip across the primary display height.
    private static func convertCGWindowRectToAppKit(_ cgRect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else {
            return cgRect
        }
        let primaryHeight = primary.frame.height
        let flippedY = primaryHeight - cgRect.origin.y - cgRect.height
        return NSRect(
            x: cgRect.origin.x,
            y: flippedY,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
