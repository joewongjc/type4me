import Foundation

/// Runtime identity derived from the bundle. Public builds keep legacy storage;
/// personal builds can live side-by-side with separate preferences and files.
enum AppIdentity {
    static let publicBundleIdentifier = "com.type4me.app"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? publicBundleIdentifier
    }

    static var isPublicBundle: Bool {
        bundleIdentifier == publicBundleIdentifier
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Type4Me"
    }

    static var applicationSupportDirectoryName: String {
        isPublicBundle ? "Type4Me" : displayName
    }

    static var applicationSupportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var keychainScalarService: String {
        isPublicBundle ? "com.type4me.scalar" : "\(bundleIdentifier).scalar"
    }

    static var keychainGroupedService: String {
        isPublicBundle ? "com.type4me.grouped" : "\(bundleIdentifier).grouped"
    }

    static var primaryURLScheme: String {
        if let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] {
            for type in types {
                if let schemes = type["CFBundleURLSchemes"] as? [String], let first = schemes.first {
                    return first
                }
            }
        }
        return isPublicBundle ? "type4me" : bundleIdentifier
    }

    static func url(_ action: String) -> URL? {
        URL(string: "\(primaryURLScheme)://\(action)")
    }
}
