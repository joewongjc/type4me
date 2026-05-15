import AppKit

/// Keeps the running app's Dock icon in sync with the active theme.
///
/// This is additive: the bundle's default icon (Info.plist `CFBundleIconFile`)
/// stays the original Type4Me logo. This only swaps the *running app's* Dock
/// icon when the Evolution theme is active; the Warm/Classic theme reverts to
/// the bundle default. The Finder / Launchpad icon always shows the bundle
/// default — macOS only lets a running app override its Dock icon.
enum AppIconThemeSync {

    /// The bundled techwear icon, used while the Evolution theme is active.
    private static let evolutionIconResource = "AppIconCold"

    /// Apply the Dock icon for `theme`. Safe to call from any thread.
    static func apply(_ theme: AppTheme) {
        DispatchQueue.main.async {
            switch theme {
            case .coldIndustrial:
                if let path = Bundle.main.path(forResource: evolutionIconResource, ofType: "icns"),
                   let image = NSImage(contentsOfFile: path) {
                    NSApplication.shared.applicationIconImage = image
                }
            case .warm:
                // nil restores the bundle's default icon (the original logo).
                NSApplication.shared.applicationIconImage = nil
            }
        }
    }
}
