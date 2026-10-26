import Foundation

/// The app's bundle version data, with display-safe fallbacks for development
/// and test hosts that do not provide Type4Me's Info.plist values.
struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let buildNumber: String

    init(version: String?, buildNumber: String?) {
        self.version = Self.displayValue(version)
        self.buildNumber = Self.displayValue(buildNumber)
    }

    init(infoDictionary: [String: Any]?) {
        self.init(
            version: infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: infoDictionary?["CFBundleVersion"] as? String
        )
    }

    static var current: Self {
        Self(infoDictionary: Bundle.main.infoDictionary)
    }

    /// Compact form used next to the sidebar Settings navigation item.
    var compactLabel: String {
        "v\(version)(\(buildNumber))"
    }

    var debugLabel: String {
        "\(version) (\(buildNumber))"
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }
}
