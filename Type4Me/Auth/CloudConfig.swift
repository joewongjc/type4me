import Foundation

/// Cloud service configuration, loaded from Secrets.plist (not checked into git).
/// Copy Secrets.plist.example → Secrets.plist and fill in real values to build.
enum CloudConfig {

    // MARK: - Values

    static let supabaseURL: String = value(for: "SUPABASE_URL")
    static let supabaseAnonKey: String = value(for: "SUPABASE_ANON_KEY")
    static let proxyURLChina: String = value(for: "PROXY_URL_CN")
    static let proxyURLGlobal: String = value(for: "PROXY_URL_GLOBAL")

    /// Auto-select proxy URL based on locale.
    static var proxyURL: String {
        if let override = UserDefaults.standard.string(forKey: "tf_cloudProxyURL"), !override.isEmpty {
            return override
        }
        if Locale.current.region?.identifier == "CN" {
            return proxyURLChina
        }
        return proxyURLGlobal
    }

    // MARK: - Plist Loader

    private static let secrets: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            #if DEBUG
            print("[CloudConfig] Secrets.plist not found. Copy Secrets.plist.example and fill in values.")
            #endif
            return [:]
        }
        return dict
    }()

    private static func value(for key: String) -> String {
        guard let v = secrets[key] as? String, !v.isEmpty, !v.hasPrefix("YOUR_") else {
            return ""
        }
        return v
    }
}
