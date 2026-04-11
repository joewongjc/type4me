// Type4Me/Auth/CloudConfig.swift

import Foundation

enum CloudRegion: String, Codable {
    case cn = "cn"
    case overseas = "overseas"
}

enum CloudConfig {
    // API endpoints
    // TODO: switch to domain names before release (cn.api.type4me.com / us.api.type4me.com)
    static let cnAPIEndpoint = "http://115.190.217.85"
    static let usAPIEndpoint = "http://115.190.217.85"

    // Pricing display
    static let weeklyPriceCN = "¥7"
    static let weeklyPriceUS = "$1.50"

    // Current region (persisted)
    static var currentRegion: CloudRegion {
        get {
            CloudRegion(rawValue: UserDefaults.standard.string(forKey: "tf_cloud_region") ?? "") ?? .overseas
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "tf_cloud_region")
        }
    }

    static var apiEndpoint: String {
        currentRegion == .cn ? cnAPIEndpoint : usAPIEndpoint
    }
}
